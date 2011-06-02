#non-gem requirements (included with ruby):
require 'matrix'
require 'digest/md5'
require 'fileutils'
require 'tempfile'
#gems requirements:
require 'rubygems'
require 'haml'
require 'sinatra'
require 'uuid'
require 'yaml'
require 'ferret' #actually using the 'jk-ferret' gem
# require 'mime/types'
#other requirements:
#the program 'pdftotext' from package 'poppler-utils'
#tesseract OCR package

include Math
include Ferret

class Vector
  def unit #returns a unit vector
    self/self.r
  end
end

class Vertex
  attr_reader :iden, :links, :times, :type
  attr_accessor :position, :searchScore
  def initialize(web, position, type)
    @iden = $uuid.generate if @iden == nil
    @web = web
    @position = position
    @searchScore = 0.0
    @links = []
    @times = []
    @type = type

     update_times_and_index
  end
  #name, content, type
  
  def update_times_and_index
    #update the time
    @times << Time.new
    #update the index
    @web.index.delete(@iden)
    @web.index << {:id=>@iden, :title=>name, :content=>content, :update_time=>@times[-1].to_s, :type=>@type.to_s}
    #signal that the search results need updating
    @web.searchNeedsUpdate = true
  end
  
  def prepare_for_deletion
    #nothing to do by default
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
end

#TODO: COMPLETE THIS
#possible types: URL, to external ThoughtWeb
class ExternalLink < Vertex
  def initialize(web, position, name, link)#,type)
    
    super(web, position, :externalLink)
  end
end

#TODO: MAKE REFERENCE A CLASS; FOR NOW JUST A STRING
class TWDocument < Vertex
  attr_reader :iden, :filename, :mimeType, :hash, :ocr
  attr_accessor :reference
  def initialize(web, position, tempfile, filename, mimeType, reference, option)
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

    @iden = $uuid.generate
    FileUtils.mkdir('files/' + @iden)
    FileUtils.cp(tempfile.path, path)
    
    super(web, position, :document) #needs to come after FileUtils stuff so we can read from the doc
  end
  
  def path
    'files/' + @iden + '/' + @filename
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
  
  def content
    #TODO: INCLUDE MORE TYPES
    if @mimeType == 'text/plain' #TODO: GET mime/types GEM WORKING SO WE CAN TELL WHAT OTHER TYPES ARE TEXT
      read
    elsif @ocr #TODO: IMPLIMENT OCR USING TESSERACT (AND IMAGEMAGIK???)
      #NOTE: SHOULD SAVE TEXT AFTER OCR SO DON'T HAVE TO DO EVERY TIME text IS CALLED (HAPPENS WHENEVER A THOUGHT IT UPDATED)
      
    elsif @mimeType == 'application/pdf' #TODO: TRY pdf-reader GEM
      Kernel.system("pdftotext #{path} ./temppdf.txt")
      text = File.read('temppdf.txt')
      FileUtils.rm('temppdf.txt')
      return text
    else #need to return something
      ''
    end
  end
  
  def prepare_for_deletion #it's a shame ruby doesn't have a destructor...
    FileUtils.rm_r('files/' + @iden)
  end
end

class Thought < Vertex
  attr_reader :title, :comment, :links, :iden, :times
  attr_accessor :position, :searchScore
  def initialize(web, position, title, comment)
    @title = title
    @comment = comment
    super(web, position, :thought)
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
  attr_reader :vertices, :searchTerm, :searchType
  attr_accessor :index, :searchNeedsUpdate, :colorBySearch
  
  def self.load(file)
    web = YAML.load(File.open(file))
    web.index = Index::Index.new(:path=> 'test.ferret') #TODO: MAKE GENERAL
    return web
  end
  
  def save(file)
    File.open(file, "w") {|f| f.write(self.to_yaml) }
    @index.flush
  end
  
  def initialize(width, height)
    @index = Index::Index.new(:path=> 'test.ferret') #TODO: MAKE GENERAL
    @vertices = []
#     @recent = []
    @selected = []
    @center = nil
    @searchType = :simple
    @searchTerm = ""
    @searchNeedsUpdate = false
    @maxSearchScore = 0.0
    @colorBySearch = false
    @width = width - 5
    @height = height - 5
    FileUtils.mkdir('files')
  end

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
    repeat_search if @colorBySearch and @searchNeedsUpdate
    
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
	<svg:a xlink:href="/select/#{ver.iden}">
      	  <svg:title>#{content}</svg:title>
	  <svg:g transform="translate(#{p[0]},#{p[1]}) scale(-1,1)">
	    <svg:circle r="50" style="fill: #{fillColor}; stroke: #{strokeColor}; stroke-width: #{strokeWidth}" />
	    <svg:text font-family="Verdana" font-size="20" fill="black" >
	      <svg:textPath xlink:href="#cpath">
		#{ver.name}
	      </svg:textPath>
	    </svg:text>
	  </svg:g>
	</svg:a>	
	<svg:g transform="translate(#{p[0]},#{p[1]}) scale(1,-1)">
	    <svg:text x="-30" y="0" font-family="Verdana" font-size="20" fill="black" >
	      <svg:a xlink:href="/view/#{ver.iden}">
		V
	      </svg:a>
	      <svg:a xlink:href="/edit/#{ver.iden}">
		E
	      </svg:a>
	      <svg:a xlink:href="/center/#{ver.iden}">
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
  
  def add_thought(title,comment)
    @vertices << Thought.new(self, random_position, title, comment)
    update_positions
  end  
  
  def add_document(tempfile, filename, mimeType, reference, option)
    @vertices << TWDocument.new(self, random_position, tempfile, filename, mimeType, reference, option)
    update_positions    
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
  end
  
  def link_selected
    @selected.each{|id| lookup_vertex(id).link(@selected)}
    update_positions
  end

  def unlink_selected
    @selected.each{|id| lookup_vertex(id).unlink(@selected)}
    update_positions
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
    update_maxSearchScore #TODO: BETTER PLACE TO PUT THIS? WILL BE CALLED TWICE FOR NON-SIMPLE SEARCHES
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
    
    return simpleScores, assocScores
  end
  
  def association_search(st = nil)
    ferretScores, assocScores = find_scores(st)
    @vertices.zip(assocScores.to_a.flatten).each{|(ver,sc)| ver.searchScore = sc} #assign the new scores  
    update_maxSearchScore
    @searchType = :assoc #need this at end because find_scores does a simple search
  end
  
  def difference_search(st = nil)
    ferretScores, assocScores = find_scores(st)
    diffScores = assocScores - ferretScores
    @vertices.zip(diffScores.to_a.flatten).each{|(ver,sc)| ver.searchScore = sc} #assign the new scores 
    update_maxSearchScore
    @searchType = :diff #need this at end because find_scores does a simple search
  end
 
  #returns an array of [id, score] pairs sorted by score from highest to lowest. If the score is zero then the pair isn't returned
  def sorted_search_results
    if @searchNeedsUpdate
      repeat_search
      @searchNeedsUpdate = false
    end
    
    #TODO: SORT_BY IS SUPPOSED TO BE SLOW? CHECK AND MOVE TO DIFFERENT SORT
    @vertices.collect{|ver| [ver.iden, ver.searchScore]}.reject{|(id,sc)| sc == 0.0}.sort_by{|(id,sc)| -sc} #negative sign makes it sort from highest to lowest
  end
end

#globals
$uuid = UUID.new
$redirect = '/web'
$vertex = nil

get '/' do
  content_type 'application/xml', :charset => 'utf-8'
  @center = nil
  haml :sizer
end

get '/size/:width/:height' do
  width = params[:width].to_i
  height = params[:height].to_i
  $web = Web.new(width,height)    
#   $web = Web.load('test.yml') #TODO: MAKE GENERAL
#   $web.set_width_height(width,height)
  redirect $redirect
end

get '/web' do
  content_type 'application/xml', :charset => 'utf-8'
  $redirect = '/web'
  redirect '/' if $web == nil #in case you visit /web before sizing
  haml :web
end

get '/search' do
  content_type 'application/xml', :charset => 'utf-8'
  $redirect = '/search'
  haml :search
end

get '/new_document' do
  content_type 'application/xml', :charset => 'utf-8'
  haml :new_document  
end

get '/new_thought' do
  content_type 'application/xml', :charset => 'utf-8'
  haml :new_thought  
end

get '/view_thought/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  haml :view_thought
end

get '/view_document/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  haml :view_document
end

get '/edit_thought/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  haml :edit_thought
end

get '/edit_document/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  haml :edit_document
end

get '/view/:iden' do
  iden = params[:iden]
  $vertex = $web.lookup_vertex(iden)
  if $vertex == nil #could hapen if you delete the vertex while in viewing mode
    $redirect = '/web'
  elsif $vertex.type == :thought
    $redirect = '/view_thought/' + iden
  elsif $vertex.type == :document
    $redirect = '/view_document/' + iden
  end
  redirect $redirect  end

get '/edit/:iden' do
  iden = params[:iden]
  $vertex = $web.lookup_vertex(iden)
  if $vertex == nil #could hapen if you delete the vertex while in editing mode
    $redirect = '/web'
  elsif $vertex.type == :thought
    $redirect = '/edit_thought/' + iden
  elsif $vertex.type == :document
    $redirect = '/edit_document/' + iden
  end
  redirect $redirect  
end

get '/doc/:iden/:filename' do
  doc = $web.lookup_vertex(params[:iden])
  content_type doc.type
  doc.read
end

get '/center/:iden' do
  iden = params[:iden]
  $web.toggle_center(iden)
  redirect $redirect
end

get '/select/:iden' do
  iden = params[:iden]
  $web.toggle_select(iden)
  redirect $redirect
end

get '/delete' do
  $web.delete_selected
  redirect $redirect
end

get '/link' do
  $web.link_selected
  redirect $redirect
end

get '/unlink' do
  $web.unlink_selected
  redirect $redirect
end

get '/deselect' do
  $web.deselect_all
  redirect $redirect
end

get '/save' do
  $web.save('test.yml') #TODO: MAKE GENERAL
  redirect $redirect
end

get '/toggle_search_coloring' do
  $web.colorBySearch = (not $web.colorBySearch)
  redirect $redirect
end

post '/new_thought' do
  title = params[:title]
  comment = params[:comment]
  $web.add_thought(title,comment)
  redirect $redirect
end

post '/new_document' do
puts params[:file].to_s
#TODO: REWRITE FOLLOWING until CLAUSE
  unless params[:file] &&
         (tmpfile = params[:file][:tempfile]) &&
         (name = params[:file][:filename])
    @error = "No file selected"
    return haml(:upload)
  end

  $web.add_document(params[:file][:tempfile], params[:file][:filename], params[:file][:type], params[:reference], params[:opt])
  redirect $redirect
end

post '/save_thought_edit' do
  #$vertex was already set to the thought we want in get '/edit/:iden'
  $vertex.title = params[:title]
  $vertex.comment = params[:comment]
  redirect $redirect
end

post '/save_document_edit' do
  #$vertex was already set to the document we want in get '/edit/:iden'
  $vertex.reference = params[:reference] #TODO: MAKE WORK WITH NON STRING REFERENCES
  redirect $redirect
end

post '/search' do
  searchTerm = params[:searchterm]
  searchType = params[:searchtype]
  #TODO: REPALCE WITH SWITCH?
  if searchType == 'simple'
    $web.simple_search(searchTerm)
  elsif searchType == 'assoc'
    $web.association_search(searchTerm)
  elsif searchType == 'diff'
    $web.difference_search(searchTerm)    
  end
  redirect $redirect
end

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


@@ web
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 ThoughtWeb
      %p
        %a{:href=>'/new_thought'}="New Thought"
        %a{:href=>'/new_document'}="New Document"
    =haml(:control_div)

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
      %form{:action=>'/save_thought_edit', :method=>'post'}
        %p
          Title:
          %input{:name=>'title', :size=>'40', :type=>'text', :value=>$vertex.title}
          Text:
          %textarea{:name=>"comment", :rows=>"4", :cols=>"30"}=$vertex.comment
          %input{:type=>'submit', :value=>'Save Changes'}
      %p
        %a{:href=>'/web'}="New"
        %a{:href=>"/view/#{$vertex.iden}"}="View"
        %a{:href=>"/select/#{$vertex.iden}"}="Select"
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
      %form{:action=>'/save_document_edit', :method=>'post'}
        %p
          Reference:
          %input{:name=>'reference', :size=>'40', :type=>'text', :value=>$vertex.reference}
          %input{:type=>'submit', :value=>'Save Changes'}
      %p
        %a{:href=>'/web'}="New"
        %a{:href=>"/view/#{$vertex.iden}"}="View"
        %a{:href=>"/select/#{$vertex.iden}"}="Select"
    =haml(:control_div)

@@ view_thought
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 View Thought
      %p
        Title: 
        =$vertex.title
        %br
        Text: 
        =$vertex.comment
      %p
        %a{:href=>'/web'}="New"
        %a{:href=>"/edit/#{$vertex.iden}"}="Edit"
        %a{:href=>"/select/#{$vertex.iden}"}="Select"
    =haml(:control_div)

@@ view_document
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    =haml(:svg_div)
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 View Document
      %p
        Reference: 
        =$vertex.reference
        %br
        %a{:href=>"/doc/#{$vertex.iden}/#{$vertex.filename}"}="Download #{$vertex.filename}"
      %p
        %a{:href=>'/web'}="New"
        %a{:href=>"/edit/#{$vertex.iden}"}="Edit"
        %a{:href=>"/select/#{$vertex.iden}"}="Select"
    =haml(:control_div)

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
      %form{:action=>'/search', :method=>'post'} 
        %p
          Search: 
          %input{:name=>'searchterm', :size=>'40', :type=>'text', :value=>$web.searchTerm}
          %input{:type=>'submit', :value=>'Search'}
          %br
          - if $web.searchType == :simple
            %input{:type=>'radio', :name=>'searchtype', :value=>'simple', :id=>'simple', :checked=>'checked'}
          - else
            %input{:type=>'radio', :name=>'searchtype', :value=>'simple', :id=>'simple'}
          %label{:for=>'simple'}='Simple'
          - if $web.searchType == :assoc
            %input{:type=>'radio', :name=>'searchtype', :value=>'assoc', :id=>'assoc', :checked=>'checked'}
          - else
            %input{:type=>'radio', :name=>'searchtype', :value=>'assoc', :id=>'assoc'}
          %label{:for=>'assoc'}='Assoc'
          - if $web.searchType == :diff
            %input{:type=>'radio', :name=>'searchtype', :value=>'diff', :id=>'diff', :checked=>'checked'}
          - else
            %input{:type=>'radio', :name=>'searchtype', :value=>'diff', :id=>'diff'}
          %label{:for=>'diff'}='Diff'
      %h3 Results:
      %ol
        - $web.sorted_search_results.each do |(id,score)|
          %li
            %strong=$web.lookup_vertex(id).name
            with score
            =score
            %a{:href=>"/view/#{id}"}="V"
            %a{:href=>"/edit/#{id}"}="E"
            %a{:href=>"/center/#{id}"}="C" 
            %a{:href=>"/select/#{id}"}="S" 
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
      %form{:action=>'/new_thought', :method=>'post'} 
        %p
          Title:
          %input{:name=>'title', :size=>'40', :type=>'text'} 
          Text:
          %textarea{:name=>"comment", :rows=>"4", :cols=>"30"}
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
      %form{:action=>"/new_document", :method=>'post', :enctype=>"multipart/form-data"} 
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
          %input{:type=>"submit",:value=>"Upload"}
      %p
        %a{:href=>'/web'}="New"
    =haml(:control_div)

@@ svg_div
%div{:id=>"page", :style=>"position: absolute; top: 0%; left: 0%; z-index: -1;"}
  =$web.to_svg
    
@@ control_div
%div{:id=>"control", :style=>"width: 300px; float: right; clear:right ; border-width: 0px 1px 1px 1px; border-style: solid; border-color: black;"} 
  %p{:style=>"text-align: center;"}
    %a{:href=>'/link'}='Link' 
    %a{:href=>'/unlink'}='Unlink' 
    %a{:href=>'/delete'}='Delete' 
    %a{:href=>'/deselect'}='Deselect'
    %a{:href=>'/web'}='New'
    %a{:href=>'/search'}='Search'
    %a{:href=>'/toggle_search_coloring'}='(Toggle Coloring)'
    %a{:href=>'/save'}='Save'