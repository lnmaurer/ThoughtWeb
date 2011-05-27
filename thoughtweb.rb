#require 'svg/svg'
require 'rubygems'
require 'haml'
require 'sinatra'
require 'uuid'
require 'yaml'
require 'matrix'
require 'ferret' #actually using jk-ferret gem
include Math
include Ferret

class Vector
  def unit
    self/self.r
  end
end


class Thought
  attr_reader :title, :comment, :docs, :links, :iden, :times
  attr_accessor :position
  def initialize(index, position, title, comment)#, docs)
    @index = index
    @position = position
    @title = title
    @comment = comment
#     @docs = docs
    @links = []
    @iden = $uuid.generate
    @times = []
    
    update_times_and_index
  end
  
  def update_times_and_index
    @times << Time.new
    @index.delete(@iden)
    @index << {:id=>@iden, :title=>@title, :comment=>@comment, :update_time=>@times[-1].to_s}
  end
  
  def link(idens)
    idens.each do |iden| #also works with idens as a string containing just one iden?
      unless @links.include?(iden) or iden == @iden
	@links << iden
	update_times_and_index
      end
    end
  end
  
  def unlink(idens)
    idens.each do |iden| #also works with idens as a string containing just one iden?
      if @links.include?(iden)
	@links.delete(iden)
	update_times_and_index
      end    
    end
  end
  
  def comment=(c)
    @comment = c
    update_times_and_index
  end
  
  def title=(t)
    @title = t
    update_times_and_index
  end
end

class Web
  attr_reader :file, :thoughts
  def initialize(width, height, file = nil)
    if file==nil
      @index = Index::Index.new() #TODO: make persistent
      @thoughts = []
      @recent = []
      @selected = []
      @center = nil
    else
      
    end
    @width = width -5
    @height = height -5
  end
  
#   def position(iden)
#     @positions[@thoughts.find_index{|t| t.iden == iden}]
#   end
  
  def add_thought(title,comment)
    @thoughts << Thought.new(@index, Vector[(@width-100)*(rand-0.5),(@height-100)*(rand-0.5)], title, comment)
    update_positions
  end
  
  def lookup_thought(id)
    @thoughts.find{|t| t.iden == id}
  end
  
  def update_positions
    desiredSpacing = ((@width+@height)/@thoughts.size.to_f)**(1/3.0)
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
    
    velocities = Array.new(@thoughts.size, Vector[0,0])
    count = 0
    ke = 0
    
    begin
      forces = []
      
      #loop over all verticies
      @thoughts.each_with_index do |th|
	pos = th.position
	x = pos[0]
	y = pos[1]
	
	#force due to potential
	#from cosh potential
	force = Vector[-sin(PI/2*x/w)/cos(PI/2*x/w)**2, -sin(PI/2*y/h)/cos(PI/2*y/h)**2]*potC
	
	#force due to springs
	th.links.each do |link|
	  pos2 = lookup_thought(link).position
	  r = pos2 - pos
	  force += r.unit*k*(r.r - restLength)
	end
	
	#force due to charges
	@thoughts.each do |th2|
	  unless th == th2 #ignore itself
	    pos2 = th2.position
	    r = pos - pos2
	    force += r.unit*chargeC/r.r**2
	  end
	end
	
	#TODO: TAKE THIS OUTSIDE OF LOOP
	#force to center a thought -- like a spring with zero rest length pulling towards center
	if th.iden == @center
	  force += -1*pos*centeringC
	end

	forces << force
      end
      oldPos = @thoughts.collect{|th| th.position}
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
print "KE: #{ke} timestep: #{timestep}\n"

      #store the new positions in the thoughts
      @thoughts.zip(newPos).each{|(th,pos)| th.position = pos}

    end while ke > timestep*@thoughts.size/10.0
  end
  
  def to_yaml
    
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
  
  def to_svg(search="")
    svg = %Q&
      <svg:svg width="#{@width}px" height="#{@height}px" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1">
        <svg:g transform="translate(#{(@width-5)/2.0},#{(@height-5)/2.0}) scale(1,-1)"> 
	  <svg:defs>
	    <svg:path id="cpath" d="M50,0 a50,50 0 1,0 0,.000001" />
	  </svg:defs>\n\n&
    #draw links between thoughts
    @thoughts.each do |th|
      pos = th.position
      th.links.each do |th2id|
	pos2 = lookup_thought(th2id).position
	#color the edges according to the following
	if @selected.include?(th.iden) and @selected.include?(th2id)
	  color = "red" #verticies at both ends selected
	elsif @selected.include?(th.iden) or @selected.include?(th2id)
	  color = "orange" #vertex at one end selected
	else
	  color = "black" #neither vertex selected
	end
	svg << %Q&<svg:line x1="#{pos[0]}" y1="#{pos[1]}" x2="#{pos2[0]}" y2="#{pos2[1]}" style="fill: none; stroke: #{color}; stroke-width: 10px;" />\n&
      end
    end
    #draw thought bubbles
    @thoughts.each do |t|
      p = t.position
      svg << %Q\
	<svg:a xlink:href="/select/#{t.iden}">
      	  <svg:title>#{t.comment}</svg:title>
	  <svg:g transform="translate(#{p[0]},#{p[1]}) scale(-1,1)">
	    <svg:circle r="50" style="fill: #{@selected.include?(t.iden) ? 'magenta' : 'white'}; stroke: red; stroke-width: 1" />
	    <svg:text font-family="Verdana" font-size="20" fill="black" >
	      <svg:textPath xlink:href="#cpath">
		#{t.title}
	      </svg:textPath>
	    </svg:text>
	  </svg:g>
	</svg:a>	
	<svg:g transform="translate(#{p[0]},#{p[1]}) scale(1,-1)">
	    <svg:text x="-30" y="0" font-family="Verdana" font-size="20" fill="black" >
	      <svg:a xlink:href="/view/#{t.iden}">
		V
	      </svg:a>
	      <svg:a xlink:href="/edit/#{t.iden}">
		E
	      </svg:a>
	      <svg:a xlink:href="/center/#{t.iden}">
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

  def delete_selected
    @thoughts.each{|th| th.unlink(@selected)} #delete any links to the selected thoughts
    @selected.each do |id|
      @index.delete(id) #delete each selected thought from @index
      @thoughts.delete_if{|th| th.iden == id} #then delete from @thoughts
    end
    deselect_all
    update_positions
  end
  
  def link_selected
    @selected.each{|id| lookup_thought(id).link(@selected)}
    update_positions
  end

  def unlink_selected
    @selected.each{|id| lookup_thought(id).unlink(@selected)}
    update_positions
  end  
  
  def deselect_all
    @selected = []
  end
  
end

#globals
$uuid = UUID.new

get '/' do
  content_type 'application/xml', :charset => 'utf-8'
  @center = nil
  haml :sizer
end

get '/size/:width/:height' do
  width = params[:width].to_i
  height = params[:height].to_i
  $web = Web.new(width,height)
  redirect '/web'
end

get '/web' do
  content_type 'application/xml', :charset => 'utf-8'
  redirect '/' if $web == nil #in case you visit /web before sizing
  haml :web
end

get '/edit/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  iden = params[:iden]
  $thought = $web.lookup_thought(iden)
  haml :edit
end

get '/view/:iden' do
  content_type 'application/xml', :charset => 'utf-8'
  iden = params[:iden]
  $thought = $web.lookup_thought(iden)
  haml :view
end

get '/center/:iden' do
  iden = params[:iden]
  $web.toggle_center(iden)
  redirect '/web'
end

get '/select/:iden' do
  iden = params[:iden]
  $web.toggle_select(iden)
  redirect '/web'
end

get '/delete' do
  $web.delete_selected
  redirect '/web'
end

get '/link' do
  $web.link_selected
  redirect '/web'
end

get '/unlink' do
  $web.unlink_selected
  redirect '/web'
end

get '/deselect_all' do
  $web.deselect_all
  redirect '/web'
end

post '/new' do
  title = params[:title]
  comment = params[:comment]
  $web.add_thought(title,comment)
  redirect '/web'
end

post '/save_edit' do
  #$thought was already set to the thought we want in get '/edit/:iden'
  $thought.title = params[:title]
  $thought.comment = params[:comment]
  redirect '/web'
end

post '/search' do
  search = params[:search]
  
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
    %div{:id=>"page", :style=>"position: absolute; top: 0%; left: 0%; z-index: -1;"}
      =$web.to_svg("")
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 New
      %form{:action=>'/new', :method=>'post'} 
        %p
          Title:
          %input{:name=>'title', :size=>'40', :type=>'text'} 
          Text:
          %textarea{:name=>"comment", :rows=>"4", :cols=>"30"}
          %input{:type=>'submit', :value=>'Create Thought'}   
    %div{:id=>"control", :style=>"width: 300px; float: right; clear:right ; border-width: 0px 1px 1px 1px; border-style: solid; border-color: black;"} 
      %p{:style=>"text-align: center;"}
        %a{:href=>'/link'}="Link" 
        %a{:href=>'/unlink'}="Unlink" 
        %a{:href=>'/delete'}="Delete" 
        %a{:href=>'/deselect_all'}="Deselect All" 
        %a{:href=>'/undo'}="Undo" 
        %a{:href=>'/redo'}="Redo"

@@ edit
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    %div{:id=>"page", :style=>"position: absolute; top: 0%; left: 0%; z-index: -1;"}
      =$web.to_svg("")
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 Edit
      %form{:action=>'/save_edit', :method=>'post'} 
        %p
          Title:
          %input{:name=>'title', :size=>'40', :type=>'text', :value=>$thought.title}
          Text:
          %textarea{:name=>"comment", :rows=>"4", :cols=>"30"}=$thought.comment
          %input{:type=>'submit', :value=>'Save Changes'}
      %p
        %a{:href=>'/web'}="New Thought"
    %div{:id=>"control", :style=>"width: 300px; float: right; clear:right ; border-width: 0px 1px 1px 1px; border-style: solid; border-color: black;"} 
      %p{:style=>"text-align: center;"}
        %a{:href=>'/link'}="Link" 
        %a{:href=>'/unlink'}="Unlink" 
        %a{:href=>'/delete'}="Delete" 
        %a{:href=>'/deselect_all'}="Deselect All" 
        %a{:href=>'/undo'}="Undo" 
        %a{:href=>'/redo'}="Redo"

@@ view
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0 plus SVG 1.1//EN" "http://www.w3.org/2002/04/xhtml-math-svg/xhtml-math-svg.dtd">
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en"}
  %head
    %meta{"http-equiv" => "Content-type", :content =>" text/html;charset=UTF-8"}
    %title="ThoughtWeb"
  %body{:style=>"margin: 0px;"}
    %div{:id=>"page", :style=>"position: absolute; top: 0%; left: 0%; z-index: -1;"}
      =$web.to_svg("")
    %div{:id=>"newedit", :style=>"width: 300px; float: right; border-width: 1px; border-style: solid; border-color: black;"}    
      %h2 View
      %p
        Title: 
        =$thought.title
        %br
        Text: 
        =$thought.comment
      %p
        %a{:href=>'/web'}="New Thought"
        %a{:href=>"/edit/#{$thought.iden}"}="Edit Thought"
    %div{:id=>"control", :style=>"width: 300px; float: right; clear:right ; border-width: 0px 1px 1px 1px; border-style: solid; border-color: black;"} 
      %p{:style=>"text-align: center;"}
        %a{:href=>'/link'}="Link" 
        %a{:href=>'/unlink'}="Unlink" 
        %a{:href=>'/delete'}="Delete" 
        %a{:href=>'/deselect_all'}="Deselect All" 
        %a{:href=>'/undo'}="Undo" 
        %a{:href=>'/redo'}="Redo"
