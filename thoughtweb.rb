#non-gem requirements (included with ruby):
require 'matrix'
require 'digest/md5'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'yaml'
require 'open3'
#gems requirements:
require 'rubygems'
require 'haml'
require 'sinatra'
require 'uuid'
require 'ferret' #actually using the 'jk-ferret' gem
require 'sanitize'
# require 'mime/types'
#other requirements:
#the program 'pdftotext' from package 'poppler-utils'
#ImageMagick for converting files to a format that can be OCRed
#tesseract OCR package (version 2 or 3, OCRopus code is written but commented out due to a bug in OCRopus)

include Math
include Ferret

class Vector
  def unit #returns a unit vector
    self/self.r
  end
end

#TODO: IMPROVE UPDATE MECHANISMS SO NOT SO ROUNDABOUT, ESPECIALLY NOW THAT THREADS CAN ADD INFO AFTER DOCUMENTS ARE CREATED

#TODO: ADD EDGE CLASS? CERTAINLY SHOULD HAVE STRENGTH OF LINK, BUT MAYBE ALSO COMMENTS AND TAGS

class Vertex
  attr_reader :iden, :links, :times, :type
  attr_accessor :position, :searchScore
  def initialize(web, position, type, tags)
    @iden = $uuid.generate if @iden == nil
    @web = web
    @position = position
    @searchScore = 0.0
    @links = []
    @times = []
    @tags = tags.split(',').collect{|s| s.strip} #'tags' is a string
    @type = type

     update_times_and_index
  end
  
  def update_index
    #update the index
    @web.index.delete(@iden)
    @web.index << {:id=>@iden, :title=>self.name, :content=>self.content, :tags=>self.tags_string(' '), :update_time=>@times[-1].to_s, :type=>@type.to_s}
    #signal that the search results need updating
    @web.searchNeedsUpdate = true    
  end
  
  def update_times_and_index
    #update the time
    @times << Time.new
    self.update_index
  end
  
  def prepare_for_deletion
    #nothing to do by default
  end

  def tags
    self.tags_string
  end
  
  #'t' is a string
  def tags=(t)
    newTags = t.split(',').collect{|s| s.strip}
    if newTags.sort != @tags.sort #order matters for array equality, so sort them before comparing -- I assume the order of tags in the list doesn't matter
      @tags = newTags
      update_times_and_index
    end
  end
  
  def link(idens)
    changesMade = false
    idens.each do |iden| #also works with idens as a string containing just one iden?
      unless @links.include?(iden) or iden == @iden
	@links << iden
        changesMade = true
      end
    end
    
    #this way, we only call update_times_and_index once even if multiple changes were made
    update_times_and_index if changesMade
  end
  
  def unlink(idens)
    changesMade = false
    idens.each do |iden| #also works with idens as a string containing just one iden?
      if @links.include?(iden)
	@links.delete(iden)
	changesMade = true
      end    
    end
   
    update_times_and_index if changesMade
  end
  
  def tags_string(joiner = ', ')
    @tags.empty? ? '' : @tags.inject{|list, tag| list + joiner + tag}
  end
end

#TODO: COMPLETE THIS CLASS
#possible types: URL, to external ThoughtWeb
class ExternalLink < Vertex
  def initialize(web, position, name, tags, link)#,type)
    
    super(web, position, :externalLink, tags)
  end
end

#TODO: MAKE REFERENCE A CLASS; FOR NOW JUST A STRING
class TWDocument < Vertex
  attr_reader :iden, :filename, :mimeType, :hash, :ocr
  attr_accessor :reference
  def initialize(web, position, tempfile, filename, mimeType, reference, tags, option)
    @filename = filename
    if option == 'txt' #this option forces the file to be interperted as plain text
      @mimeType = 'text/plain'
    else
      @mimeType = mimeType
    end
    if reference == ''
      @reference = filename
    else
      @reference = reference
    end
    @ocr = (option == 'ocr') #if this is true, we'll do OCR later
    @hash = Digest::MD5.file(tempfile).to_s

    @iden = $uuid.generate #need to generate here so that we can make the directory
    @web = web #ditto
    FileUtils.mkdir(folder_path)
    FileUtils.cp(tempfile.path, path)
    
    super(web, position, :document, tags) #needs to come after FileUtils stuff so we can read from the doc
    
    #since OCR is costly, will only OCR it once, and save text in @ocredTxt
    if @ocr
      @ocredTxt = '' #if not done with OCR this gives the 'content' function something to return
      output = "Performing OCR on <em>#{@filename}</em>:\n"
      thread = Thread.new do
	Dir.mktmpdir do |tempDir|
	  output << "Starting image format conversion...\n"
	  Kernel.system("convert -density 400x400 #{quoted_path} #{tempDir}/tempOCR.tif") #TODO: don't convert if it's already in the right format
	  output << "Image format conversion complete!\n"
	  #the output file will be tempOCR.txt because tesseract adds the '.txt' on it's own
	  Open3.popen3("tesseract #{tempDir}/tempOCR.tif #{tempDir}/tempOCR -l eng") do |stdin, stdout, stderr, wait_thr| #TODO: option for other languages
	    while not stderr.eof
	      output << stderr.gets #for whatever reason, tesseract outpus on stderr
	    end
	  end
	  @ocredTxt = File.read(tempDir + '/tempOCR.txt')
	end
	self.update_index
      end
      @web.threads << [thread, output]
#THE FOLLOWING CODE FOR OCRopus WILL HAVE TO BE UPDATED BEFORE IT CAN REPLACE THE ABOVE TESSERACT CODE
#the following should work but doesn't because of a bug in tesseract (which OCRopus uses); it should be fixed in tesseract version 3.00, but my version OCRopus doesn't seem to know how to use that yet
#http://code.google.com/p/tesseract-ocr/issues/detail?id=265#c0
#TODO: sort file names so they're in the right order
#   Kernel.system("convert -density 400x400 #{quoted_path} #{tempDir}/temppdf.png")#TODO: don't convert if it's already in the right format
#   fileList = %x[ls #{tempDir}/*.png].gsub("\n",' ')
#   Kernel.system("ocroscript recognize #{fileList} > #{tempDir}/temppdf.hocr")
#   @ocredTxt = %x[ocroscript hocr-to-text #{tempDir}/temppdf.hocr]
    end
  end
  
  def folder_path
    @web.path + 'files/' + @iden + '/'
  end
  
  def path
    folder_path + @filename
  end
  
  def quoted_path
    '"' + path + '"'
  end
  
  def open_file
    File.open(path){|file| yeild(file)}
  end
  
  def read
    File.read(path)
  end
  
  def name
    @reference.to_s
  end
  
  #TODO: when we switch over to OCRopus, it can give output in html, so make this an option for OCRed documents
  def html_content
    
  end
  
  def content
    #TODO: SAVE CONTENT TO A VARIABLE SO WE DON'T HAVE TO READ IT OUT OF A FILE MULTIPLE TIMES. HOWEVER, DON'T SAVE THAT VARIABLE IN YAML FILES SO THAT IT'S LOADED ONCE WHEN THE WEB IS LOADED
    #TODO: INCLUDE MORE TYPES
    if @mimeType == 'text/plain' #TODO: GET mime/types GEM WORKING SO WE CAN TELL WHAT OTHER TYPES ARE TEXT
      self.read
    elsif @ocr
      @ocredTxt
    elsif @mimeType == 'application/pdf' #TODO: TRY pdf-reader GEM
      Dir.mktmpdir do |tempDir|
	Kernel.system("pdftotext #{quoted_path} #{tempDir}/temppdf.txt")
	text = File.read(tempDir + '/temppdf.txt')
      end
      return text
    else #need to return something
      ''
    end
  end
  
  def prepare_for_deletion #it's a shame ruby doesn't have a destructor...
    FileUtils.rm_r(folder_path)
  end
end

class Thought < Vertex
  attr_reader :title, :comment, :links, :iden, :times
  attr_accessor :position, :searchScore
  def initialize(web, position, title, comment, tags)
    @title = title
    @comment = comment
    super(web, position, :thought, tags)
  end
  
  def name
    @title
  end
  
  def content
    @comment
  end
  
  def comment=(c)
    if @comment != c
      @comment = c
      update_times_and_index
    end
  end
  
  def title=(t)
    if @title != t
      @title = t
      update_times_and_index
    end
  end
end

class Web
  attr_reader :vertices, :searchTerm, :searchType, :iden, :title
  attr_accessor :index, :searchNeedsUpdate, :colorBySearch, :threads
  
  def path
    'webs/' + @iden + '/'
  end
  
  def self.load(id)
    web = YAML.load(File.open('webs/' + id + '/web.yaml'))
    web.index = Index::Index.new(:path=> 'webs/' + id + '/index.ferret')
    web.threads = [] #since threads aren't saved in the YAML file
    return web
  end
  
  def save
    self.clean_threads
    File.open(self.path + 'web.yaml', "w") {|f| f.write(self.to_yaml) }
    @index.flush
  end
  
  def initialize(title, width, height)
    @title = title
    @vertices = []
#     @recent = []
    @threads = [] #contains [thread, output] pairs
    @selected = []
    @center = nil
    @searchType = :simple
    @searchTerm = ""
    @searchNeedsUpdate = false
    @maxSearchScore = 0.0
    @colorBySearch = false
    @width = width - 5
    @height = height - 5
    @iden = $uuid.generate
    FileUtils.mkdir(self.path)
    @index = Index::Index.new(:path=> self.path + 'index.ferret')
    FileUtils.mkdir(self.path + 'files')
#     @threadCleaner
  end

  def to_yaml_properties
    [ '@title', '@vertices', '@selected', '@center', '@searchType', '@searchTerm', '@searchNeedsUpdate', '@maxSearchScore', '@colorBySearch', '@width', '@height', '@iden']
  end  
  
  #TODO: REMOVE WIDTH AND HEIGHT FROM WEB??? MAKE A SEPERATE VIEW CLASS???
  def set_width_height(w,h)
    @width = w - 5
    @height = h - 5
    update_positions
  end
  
  def lookup_vertex(id)
    @vertices.find{|v| v.iden == id}
  end
  
  def update_positions
    desiredSpacing = ((@width+@height)/@vertices.size.to_f)**(1/3.0)
    minDim = @width > @height ? @height : @width
    potC = minDim*cos(PI/2*(minDim-50)/minDim)**2/sin(PI/2*(minDim-50)/minDim)
    chargeC = 1e7
    k = 1e2
    centeringC = 1e3
    restLength = 200
    m = 0.01
    w = (@width-100)/2.0
    h = (@height-100)/2.0
    timestep = 1
    damping = 0.5
    
    velocities = Array.new(@vertices.size, Vector[0,0])
    count = 0
    ke = 0
    
    begin
      forces = []
      
      #loop over all verticies
      @vertices.each do |ver|
	pos = ver.position
	x = pos[0]
	y = pos[1]
	
	#force due to potential
	#from cosh potential
	force = Vector[-sin(PI/2*x/w)/cos(PI/2*x/w)**2, -sin(PI/2*y/h)/cos(PI/2*y/h)**2]*potC

	#force due to springs
	ver.links.each do |link|
	  pos2 = lookup_vertex(link).position
	  r = pos2 - pos
	  force += r.unit*k*(r.r - restLength)
	end
	
	#force due to charges
	@vertices.each do |ver2|
	  unless ver == ver2 #ignore itself
	    pos2 = ver2.position
	    r = pos - pos2
	    force += r.unit*chargeC/r.r**2
	  end
	end
	
	#TODO: TAKE THIS OUTSIDE OF LOOP
	#force to center a vertex -- like a spring with zero rest length pulling towards center
	if ver.iden == @center
	  force += -1*pos*centeringC
	end

	forces << force
      end
      oldPos = @vertices.collect{|ver| ver.position}
      oldVel = velocities.dup
      while true
	#update velocities
	velocities = oldVel.zip(forces).collect{|(v,f)| v*damping + f*timestep}
	#update positions
	newPos = oldPos.zip(velocities).collect{|(p,v)| p + v*timestep}
	#check to see if any are out of bounds
	if newPos.find{|p| p[0].abs > w or p[1].abs > h} == nil
	  break #exit loop if none are
	else
	  timestep /= 2.0 #if something's out of bounds, lower timestep and try again
	  count = 0
	end
      end 
      
      oldKE = ke
      ke = velocities.inject(0){|s,v| s + m*v.r**2}
      
      if oldKE > ke
	count += 1
      end
      #if it's been a while since anything went out of bounds and timestep<1, then slowly crank it back up
      if count == 10 and timestep < 1
	count = 0
	timestep *=1.0625
      end
# print "KE: #{ke} timestep: #{timestep}\n"

      #store the new positions in the vertices
      @vertices.zip(newPos).each{|(ver,pos)| ver.position = pos}

    end while ke > timestep*@vertices.size/10.0
  end
  
  #sets iden to center if it's not. Clear center if it is
  def toggle_center(iden)
    if @center == iden
      @center = nil
    else
      @center = iden
    end
    update_positions
  end
  
  def to_svg
    self.clean_threads #TODO: FIND BETTER PLACE TO DO THIS. MAYBE A THREAD TO CLEAN UP OTHER THREADS?
    self.repeat_search if @colorBySearch and @searchNeedsUpdate
    
    svg = %Q&
      <svg:svg width="#{@width}px" height="#{@height}px" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1">
        <svg:g transform="translate(#{(@width-5)/2.0},#{(@height-5)/2.0}) scale(1,-1)"> 
	  <svg:defs>
	    <svg:path id="cpath" d="M50,0 a50,50 0 1,0 0,.000001" />
	  </svg:defs>\n\n&
    #draw links between vertices
    @vertices.each do |ver|
      pos = ver.position
      ver.links.each do |ver2id|
	pos2 = lookup_vertex(ver2id).position
	#color the edges according to the following
	if @selected.include?(ver.iden) and @selected.include?(ver2id)
	  color = "red" #verticies at both ends selected
	elsif @selected.include?(ver.iden) or @selected.include?(ver2id)
	  color = "orange" #vertex at one end selected
	else
	  color = "black" #neither vertex selected
	end
	svg << %Q&<svg:line x1="#{pos[0]}" y1="#{pos[1]}" x2="#{pos2[0]}" y2="#{pos2[1]}" style="fill: none; stroke: #{color}; stroke-width: 10px;" />\n&
      end
    end
    #draw vertex bubbles
    @vertices.each do |ver|
      p = ver.position
      strokeColor = case ver.type
      when :thought
	'red'
      when :document
	'blue'
      when :externalLink
	'green'
      end
      strokeWidth = @selected.include?(ver.iden) ? '5' : '1'
      if @colorBySearch and ver.searchScore != 0.0
	percent = (ver.searchScore/@maxSearchScore*100.0).round
	fillColor = "rgb(0%,#{percent}%,#{percent}%)"
      else
	fillColor = 'white'
      end
      if ver.content.size > 80
	content = ver.content[0,80] + '...'
      else
	content = ver.content
      end
      svg << %Q\
	<svg:a xlink:href="/select/#{@iden}/#{ver.iden}">
      	  <svg:title>#{Sanitize.clean(content)}</svg:title>
	  <svg:g transform="translate(#{p[0]},#{p[1]}) scale(-1,1)">
	    <svg:circle r="50" style="fill: #{fillColor}; stroke: #{strokeColor}; stroke-width: #{strokeWidth}" />
	    <svg:text font-family="Verdana" font-size="20" fill="black" >
	      <svg:textPath xlink:href="#cpath">
		#{Sanitize.clean(ver.name)}
	      </svg:textPath>
	    </svg:text>
	  </svg:g>
	</svg:a>	
	<svg:g transform="translate(#{p[0]},#{p[1]}) scale(1,-1)">
	    <svg:text x="-30" y="0" font-family="Verdana" font-size="20" fill="black" >
	      <svg:a xlink:href="/view/#{@iden}/#{ver.iden}">
		V
	      </svg:a>
	      <svg:a xlink:href="/edit/#{@iden}/#{ver.iden}">
		E
	      </svg:a>
	      <svg:a xlink:href="/center/#{@iden}/#{ver.iden}">
		C
	      </svg:a>
	    </svg:text>
	</svg:g>
	\
    end

    svg << %Q\
 
	</svg:g> 
        
      </svg:svg>\
  end
  
  def toggle_select(iden)
    unless @selected.include?(iden)
      @selected << iden
    else
      @selected.delete(iden)
    end
  end

  def random_position
    Vector[(@width-100)*(rand-0.5),(@height-100)*(rand-0.5)]
  end
  
  def add_thought(title, comment, tags)
    @vertices << Thought.new(self, random_position, title, comment, tags)
    update_positions
    save
  end  
  
  def add_document(tempfile, filename, mimeType, reference, tags, option)
    @vertices << TWDocument.new(self, random_position, tempfile, filename, mimeType, reference, tags, option)
    update_positions
    save
  end
  
  def delete_selected
    @vertices.each{|ver| ver.unlink(@selected)} #delete any links to the selected vertices
    @selected.each do |id|
      @index.delete(id) #delete each selected vertex from @index
      #TODO: THERE'S A BETTER WAY THAN LOOPING THROUGH ALL OF THESE TWO MORE TIMES?
      @vertices.find{|ver| ver.iden == id}.prepare_for_deletion
      @vertices.delete_if{|ver| ver.iden == id} #then delete from @vertices
    end
    deselect_all #otherwise the deleted vertices will still be in @selected, causing problems later
    @searchNeedsUpdate = true
    update_positions
    save
  end
  
  def link_selected
    @selected.each{|id| lookup_vertex(id).link(@selected)}
    update_positions
    save
  end

  def unlink_selected
    @selected.each{|id| lookup_vertex(id).unlink(@selected)}
    update_positions
    save
  end  
  
  def deselect_all
    @selected = []
  end
  
  def repeat_search
    if @searchType == :simple
      simple_search
    elsif @searchType == :assoc
      association_search
    elsif @searchType == :diff
      difference_search
    end
  end
  
  def update_maxSearchScore
    @maxSearchScore = @vertices.collect{|ver| ver.searchScore}.sort[-1]
  end
#TODO: CHECK TO SEE IF OLD SEARCH RESULTS ARE STILL GOOD BEFORE SEARCHING?  
  
  def simple_search(st = nil)
    @searchType = :simple
    @searchTerm = st unless st == nil
    
    @vertices.each{|ver| ver.searchScore = 0.0} #zero all scores since @index.search_each doesn't return 'id's with zero score
    
    @index.search_each(@searchTerm) do |id, score| #this id isn't the UUID asigned to the vertex, but the location in @index
      lookup_vertex(@index[id][:id]).searchScore = score
    end
    self.update_maxSearchScore #TODO: BETTER PLACE TO PUT THIS? WILL BE CALLED TWICE FOR NON-SIMPLE SEARCHES
    save
  end

  #idea is to first get scores from ferret (call the ferret score for the 'i'th document fs_i), then find the association score:
  #assoc_score_i = fs_i + sum_over_other_vertices(assoc_score_i*link_strenght_i,j)
  #that boils down to the matrix problem in the following method
  def find_scores(st)
    simple_search(st)
    
    m = Matrix.build(@vertices.size,@vertices.size) do |row,col|
      if row == col
	1.0 #ones on the diagonal
      elsif @vertices[row].links.include?(@vertices[col].iden)
	#TODO: CHANGE FOR DIFFERENT LINK STRENGTHS
	-0.1 #there's a link between them
      else
	0.0 #zero otherwise
      end
    end
    
    ferretScores = Matrix.column_vector(@vertices.collect{|ver| ver.searchScore})
    assocScores = m.inverse * ferretScores
    
    return ferretScores, assocScores
  end
  
  def association_search(st = nil)
    ferretScores, assocScores = find_scores(st)
    @vertices.zip(assocScores.to_a.flatten).each{|(ver,sc)| ver.searchScore = sc} #assign the new scores  
    self.update_maxSearchScore
    self.save
    @searchType = :assoc #need this at end because find_scores does a simple search
  end
  
  def difference_search(st = nil)
    ferretScores, assocScores = find_scores(st)
    diffScores = assocScores - ferretScores
    @vertices.zip(diffScores.to_a.flatten).each{|(ver,sc)| ver.searchScore = sc} #assign the new scores 
    self.update_maxSearchScore
    self.save
    @searchType = :diff #need this at end because find_scores does a simple search
  end
 
  #returns an array of [id, scwebore] pairs sorted by score from highest to lowest. If the score is zero then the pair isn't returned
  def sorted_search_results
    if @searchNeedsUpdate
      self.repeat_search
      @searchNeedsUpdate = false
    end
    
    #TODO: SORT_BY IS SUPPOSED TO BE SLOW? CHECK AND MOVE TO DIFFERENT SORT
    @vertices.collect{|ver| [ver.iden, ver.searchScore]}.reject{|(id,sc)| sc == 0.0}.sort_by{|(id,sc)| -sc} #negative sign makes it sort from highest to lowest
  end
  
  def clean_threads
    @threads.reject!{|(th,op)| not th.status} #delete all threads that aren't still running
  end
  
  def active_threads?
    @threads.find{|(th,op)| th.status} != nil
  end
  
  def active_threads
    @threads.reject{|(th,op)| not th.status}
  end
end

#TODO: MAKE SESSION CLASS TO KEEP TRACK OF ONE USER'S SESSION

#globals
$uuid = UUID.new
$redirect = '/' #TODO: MAKE PART OF NEW SESSION CLASS, OR EVEN PART OF EACH WEB (SO THAT A PERSON CAN USE MULTIPLE WEBS ADN THEY ALL KEEP TRACK OF WHERE TO REDIRECT)
$webs = {}

get '/' do
  content_type 'application/xml', :charset => 'utf-8'
  $redirect = '/'
  
  #get screen size if it's unknown
  redirect '/sizer' if $width == nil or $height == nil
  
  #make the webs/ dir if it doesn't exist
  unless File.directory?('webs/')
    FileUtils.mkdir('webs/')
  end
  
  #TODO: CHANGE TO LOADING/UNLOADING WEBS AS NEEDED
  #load past webs if they exist and haven't been loaded
  if $webs.empty? and File.exists?('webs/webs.yaml')
    YAML.load(File.open('webs/webs.yaml')).each do |id|
      $webs.merge!({id => Web.load(id)})
    end
  end
  
  haml :start
end

get '/sizer' do
  content_type 'application/xml', :charset => 'utf-8'
  haml :sizer
end

get '/delete_all' do
  $webs = {}
  FileUtils.rm_r('webs/')
  redirect '/'
end

get '/size/:width/:height' do
  $width = params[:width].to_i
  $height = params[:height].to_i
  redirect $redirect
end

get '/web/:web_iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @webIden = params[:web_iden]
  $redirect = '/web/' + @webIden
#   redirect '/' if $webs[@webIden] == nil #web doesn't exist
  haml :web
end

get '/search/:web_iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @webIden = params[:web_iden]
  $redirect = '/search/' + @webIden
  haml :search
end

get '/new_document/:web_iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @webIden = params[:web_iden]
  haml :new_document  
end

get '/new_thought/:web_iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @webIden = params[:web_iden]
  haml :new_thought  
end

get '/view_thought/:web_iden/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @iden = params[:iden]
  @webIden = params[:web_iden]
  @vertex = $webs[@webIden].lookup_vertex(@iden)
  haml :view_thought
end

get '/view_document/:web_iden/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @iden = params[:iden]
  @webIden = params[:web_iden]
  @vertex = $webs[@webIden].lookup_vertex(@iden)
  haml :view_document
end

get '/edit_thought/:web_iden/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @iden = params[:iden]
  @webIden = params[:web_iden]
  @vertex = $webs[@webIden].lookup_vertex(@iden)
  haml :edit_thought
end

get '/edit_document/:web_iden/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  @iden = params[:iden]
  @webIden = params[:web_iden]
  @vertex = $webs[@webIden].lookup_vertex(@iden)
  haml :edit_document
end

get '/view/:web_iden/:iden' do
  iden = params[:iden]
  @webIden = params[:web_iden]
  vertex = $webs[@webIden].lookup_vertex(iden)
  $redirect = '/view/' + @webIden + '/' + iden #don't want to redirect directly to view_document or view_thought since they don't have to logic for vertex == nil. #TODO: FIND A BETTER WAY TO DO THIS
  if vertex == nil #could hapen if you delete the vertex while in viewing mode
    $redirect = '/web/' + @webIden
    redirect $redirect
  elsif vertex.type == :thought
    redirect '/view_thought/' + @webIden + '/' + iden
  elsif vertex.type == :document
    redirect '/view_document/' + @webIden + '/' + iden
  end
end

get '/edit/:web_iden/:iden' do
  iden = params[:iden]
  @webIden = params[:web_iden]
  vertex = $webs[@webIden].lookup_vertex(iden)
  $redirect = '/edit/' + @webIden + '/' + iden #don't want to redirect directly to view_document or view_thought since they don't have to logic for vertex == nil
  if vertex == nil #could hapen if you delete the vertex while in editing mode
    $redirect = '/web/' + @webIden
    redirect $redirect
  elsif vertex.type == :thought
    redirect '/edit_thought/' + @webIden + '/' + iden
  elsif vertex.type == :document
    redirect '/edit_document/' + @webIden + '/' + iden
  end
end

get '/doc/:web_iden/:iden/:filename' do
  iden = params[:iden]
  @webIden = params[:web_iden]
  doc = $webs[@webIden].lookup_vertex(iden)
  content_type doc.mimeType
  doc.read
end

get '/doc_content/:web_iden/:iden/:filename' do
  iden = params[:iden]
  @webIden = params[:web_iden]
  doc = $webs[@webIden].lookup_vertex(iden)
  content_type 'text/plain'
  doc.content
end

get '/center/:web_iden/:iden' do
  @webIden = params[:web_iden]
  iden = params[:iden]
  $webs[@webIden].toggle_center(iden)
  redirect $redirect
end

get '/select/:web_iden/:iden' do
  iden = params[:iden]
  @webIden = params[:web_iden]
  $webs[@webIden].toggle_select(iden)
  redirect $redirect
end

get '/delete/:web_iden' do
  @webIden = params[:web_iden]
  $webs[@webIden].delete_selected
  redirect $redirect
end

get '/link/:web_iden' do
  @webIden = params[:web_iden]
  $webs[@webIden].link_selected
  redirect $redirect
end

get '/unlink/:web_iden' do
  @webIden = params[:web_iden]
  $webs[@webIden].unlink_selected
  redirect $redirect
end

get '/deselect/:web_iden' do
  @webIden = params[:web_iden]
  $webs[@webIden].deselect_all
  redirect $redirect
end

get '/toggle_search_coloring/:web_iden' do
  @webIden = params[:web_iden]
  web = $webs[@webIden]
  web.colorBySearch = (not web.colorBySearch)
  redirect $redirect
end

post '/new_web' do
  title = params[:title]
  newWeb = Web.new(title, $width, $height)
  newWeb.save #to make sure yaml file gets created
  $webs.merge!({newWeb.iden => newWeb})
  File.open('webs/webs.yaml', "w") {|f| f.write($webs.keys.to_yaml)} #save updated list of webs
  $redirect = 'web/' + newWeb.iden
  redirect $redirect
end

post '/new_thought/:web_iden' do
  @webIden = params[:web_iden]
  title = params[:title]
  comment = params[:comment]
  tags = params[:tags]
  $webs[@webIden].add_thought(title, comment, tags)
  redirect $redirect
end

post '/new_document/:web_iden' do
puts params[:file].to_s
#TODO: REWRITE FOLLOWING until CLAUSE
  unless params[:file] &&
         (tmpfile = params[:file][:tempfile]) &&
         (name = params[:file][:filename])
    @error = "No file selected"
    return haml(:upload)
  end

  @webIden = params[:web_iden]
  $webs[@webIden].add_document(params[:file][:tempfile], params[:file][:filename], params[:file][:type], params[:reference], params[:tags], params[:opt])
  redirect $redirect
end

post '/save_thought_edit/:web_iden/:iden' do
  iden = params[:iden]
  @webIden = params[:web_iden]
  vertex = $webs[@webIden].lookup_vertex(iden)
  vertex.title = params[:title]
  vertex.comment = params[:comment]
  vertex.tags = params[:tags]
  $redirect = '/view/' + @webIden + '/' + iden #after saving edit, redirect to viewing
  redirect $redirect
end

post '/save_document_edit/:web_iden/:iden' do
  iden = params[:iden]
  @webIden = params[:web_iden]
  vertex = $webs[@webIden].lookup_vertex(iden)
  vertex.reference = params[:reference] #TODO: MAKE WORK WITH NON STRING REFERENCES
  vertex.tags = params[:tags]
  $redirect = '/view/' + @webIden + '/' + iden #after saving edit, redirect to viewing
  redirect $redirect
end

post '/search/:web_iden' do
  @webIden = params[:web_iden]
  web = $webs[@webIden]
  searchTerm = params[:searchterm]
  searchType = params[:searchtype]
  #TODO: REPALCE WITH SWITCH?
  if searchType == 'simple'
    web.simple_search(searchTerm)
  elsif searchType == 'assoc'
    web.association_search(searchTerm)
  elsif searchType == 'diff'
    web.difference_search(searchTerm)    
  end
  redirect $redirect
end

#TODO: FIGURE OUT WAY TO REFRESH thread_div ON PAGES WE CAN'T COMPLETELY REFRESH (E.G. ONES WE'RE EDITING AND DON'T WANT TO LOSE CHANGES)

__END__

@@ sizer
!!! Strict
%html{:lang=>'en', :xmlns=>'http://www.w3.org/1999/xhtml'} 
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %script{:type=>"text/javascript"}
      var myWidth;
      var myHeight;

      myWidth = window.innerWidth;
      myHeight = window.innerHeight;
     
      window.location = '/size/' + myWidth + '/' + myHeight
    %title
  %body

@@ start
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    - unless $webs.empty?
      %h1 Existant Webs
      %ul
        - $webs.each_value do |web|
          %li
            %a{:href=>"/web/#{web.iden}"}=web.title
    %h1 New Web
    %form{:action=>'/new_web', :method=>'post'}
      %p
        Title:
        %input{:name=>'title', :size=>'40', :type=>'text'}
        %input{:type=>'submit', :value=>'Create'}
    %a{:href=>'/delete_all'}='Delete All'
  
@@ web
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    - if $webs[@webIden].active_threads?
      %meta{"http-equiv" => "refresh", :content=> "1"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 ThoughtWeb
      %p
        %a{:href=>'/new_thought/' + @webIden}="New Thought"
        %a{:href=>'/new_document/' + @webIden}="New Document"
    =haml(:control_div)
    =haml(:thread_div)

@@ edit_thought
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 Edit Thought
      %form{:action=>"/save_thought_edit/#{@webIden}/#{@iden}", :method=>'post'}
        %p
          Title:
          %input{:name=>'title', :size=>'40', :type=>'text', :value=>@vertex.title}
          %br
          Text:
          %textarea{:name=>"comment", :rows=>"4", :cols=>"30"}=@vertex.comment
          %br
          =haml(:edit_tags)
          %input{:type=>'submit', :value=>'Save Changes'}
      %p
        %a{:href=>"/view/#{@webIden}/#{@iden}"}="View"
        %a{:href=>"/select/#{@webIden}/#{@iden}"}="Select"
    =haml(:control_div)

@@ edit_document
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 Edit Document
      %form{:action=>"/save_document_edit/#{@webIden}/#{@iden}", :method=>'post'}
        %p
          Reference:
          %input{:name=>'reference', :size=>'40', :type=>'text', :value=>@vertex.reference}
          %br
          =haml(:edit_tags)
          %input{:type=>'submit', :value=>'Save Changes'}
      %p
        %a{:href=>"/view/#{@webIden}/#{@iden}"}="View"
        %a{:href=>"/select/#@webIden{@webIden}/#{@iden}"}="Select"
    =haml(:control_div)

@@ view_thought
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    - if $webs[@webIden].active_threads?
      %meta{"http-equiv" => "refresh", :content=> "1"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 View Thought
      %p
        Title: 
        =Sanitize.clean(@vertex.title)
        %br
        Text: 
        =Sanitize.clean(@vertex.comment)
        %br
        =haml(:view_tags)
      %p
        %a{:href=>"/edit/#{@webIden}/#{@iden}"}="Edit"
        %a{:href=>"/select/#{@webIden}/#{@iden}"}="Select"
    =haml(:control_div)
    =haml(:thread_div)
    
@@ view_document
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    - if $webs[@webIden].active_threads?
      %meta{"http-equiv" => "refresh", :content=> "1"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 View Document
      %p
        Reference: 
        =Sanitize.clean(@vertex.reference)
        %br
        =haml(:view_tags)
        %br
        %a{:href=>"/doc/#{@webIden}/#{@iden}/#{@vertex.filename}"}="Download #{@vertex.filename}"
        - if (@vertex.mimeType != 'text/plain') and (not @vertex.content.empty?)
          %br
          %a{:href=>"/doc_content/#{@webIden}/#{@iden}/#{@vertex.filename}.txt"}="Download as plain text"
      %p
        %a{:href=>"/edit/#{@webIden}/#{@iden}"}="Edit"
        %a{:href=>"/select/#{@webIden}/#{@iden}"}="Select"
    =haml(:control_div)
    =haml(:thread_div)
    
@@ search
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 Search
      %form{:action=>'/search/' + @webIden, :method=>'post'} 
        %p
          Search: 
          %input{:name=>'searchterm', :size=>'40', :type=>'text', :value=>$webs[@webIden].searchTerm}
          %input{:type=>'submit', :value=>'Search'}
          %br
          - if $webs[@webIden].searchType == :simple
            %input{:type=>'radio', :name=>'searchtype', :value=>'simple', :id=>'simple', :checked=>'checked'}
          - else
            %input{:type=>'radio', :name=>'searchtype', :value=>'simple', :id=>'simple'}
          %label{:for=>'simple'}='Simple'
          - if $webs[@webIden].searchType == :assoc
            %input{:type=>'radio', :name=>'searchtype', :value=>'assoc', :id=>'assoc', :checked=>'checked'}
          - else
            %input{:type=>'radio', :name=>'searchtype', :value=>'assoc', :id=>'assoc'}
          %label{:for=>'assoc'}='Assoc'
          - if $webs[@webIden].searchType == :diff
            %input{:type=>'radio', :name=>'searchtype', :value=>'diff', :id=>'diff', :checked=>'checked'}
          - else
            %input{:type=>'radio', :name=>'searchtype', :value=>'diff', :id=>'diff'}
          %label{:for=>'diff'}='Diff'
      %h3 Results:
      %ol
        - $webs[@webIden].sorted_search_results.each do |(id,score)|
          %li
            %strong=$webs[@webIden].lookup_vertex(id).name
            with score
            =score
            %a{:href=>"/view/#{@webIden}/#{id}"}="V"
            %a{:href=>"/edit/#{@webIden}/#{id}"}="E"
            %a{:href=>"/center/#{@webIden}/#{id}"}="C" 
            %a{:href=>"/select/#{@webIden}/#{id}"}="S" 
    =haml(:control_div)


@@ new_thought
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 New
      %form{:action=>'/new_thought/' + @webIden, :method=>'post'} 
        %p
          Title:
          %input{:name=>'title', :size=>'40', :type=>'text'} 
          %br
          Text:
          %textarea{:name=>"comment", :rows=>"4", :cols=>"30"}
          %br
          =haml(:enter_tags)
          %input{:type=>'submit', :value=>'Create Thought'}   
    =haml(:control_div)

@@ new_document
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2="New Document"
      %form{:action=>'/new_document/' + @webIden, :method=>'post', :enctype=>"multipart/form-data"} 
        %p
          %input{:type=>"file",:name=>"file"}
          Reference:
          %input{:name=>'reference', :size=>'40', :type=>'text'}
          %br
          Options:
          %input{:type=>'radio', :name=>'opt', :value=>'none', :id=>'none', :checked=>'checked'}
          %label{:for=>'none'}='None'
          %input{:type=>'radio', :name=>'opt', :value=>'txt', :id=>'txt'}
          %label{:for=>'txt'}='Force UTF-8'
          %input{:type=>'radio', :name=>'opt', :value=>'ocr', :id=>'ocr'}
          %label{:for=>'ocr'}='OCR'
          %br
          =haml(:enter_tags)
          %input{:type=>"submit",:value=>"Upload"}
      %p
        %a{:href=>'/web/' + @webIden}="New"
    =haml(:control_div)
    
@@ view_tags
Tags:
=Sanitize.clean(@vertex.tags)

@@ edit_tags
Tags:
%input{:name=>'tags', :size=>'40', :type=>'text', :value=>@vertex.tags}

@@ enter_tags
Tags:
%input{:name=>'tags', :size=>'40', :type=>'text'}

@@ svg_div
%div{:id=>"page", :style=>"position: absolute; top: 0%; left: 0%; z-index: -1;"}
  =$webs[@webIden].to_svg
    
@@ control_div
%div{:id=>"control", :style=>"width: 300px; float: right; clear:right ; border-width: 0px 1px 1px 1px; border-style: solid; border-color: black;"} 
  %p{:style=>"text-align: center;"}
    %a{:href=>'/link/' + @webIden}='Link' 
    %a{:href=>'/unlink/' + @webIden}='Unlink' 
    %a{:href=>'/delete/' + @webIden}='Delete' 
    %a{:href=>'/deselect/' + @webIden}='Deselect'
    %a{:href=>'/web/' + @webIden}='New'
    %a{:href=>'/search/' + @webIden}='Search'
    %a{:href=>'/toggle_search_coloring/' + @webIden}='(Toggle Coloring)'
    %a{:href=>'/'}='Home'
    
@@ thread_div
- if $webs[@webIden].active_threads?
  %div{:id=>"control", :style=>"width: 300px; float: right; clear:right ; border-width: 0px 1px 1px 1px; border-style: solid; border-color: black;"}
    %h3="Tasks running in the background:"
    - $webs[@webIden].active_threads.each do |(th,op)|
      %p=op.gsub(/\n/,'<br />')
