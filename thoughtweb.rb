require 'svg/svg'
require 'rubygems'
require 'haml'
require 'sinatra'
require 'uuid'
require 'yaml'
require 'matrix'
include Math

#ruby 1.9 makes vector not suck by default -- we'll move to that eventually
class Vector
  def length
    sqrt(self.to_a.inject(0){|s,v| s + v.to_f**2})
  end

  def /(n)
    self*(1.0/n)
  end
  
  def unit
    self/length
  end
end


class Thought
  attr_reader :title, :comment, :docs, :links, :iden, :times
  def initialize(title, comment)#, docs)
    @title = title
    @comment = comment
#     @docs = docs
    @links = []
    @iden = $uuid.generate
    @times = [Time.new]
  end
  
  def update_times
    @times << Time.new
  end
  
  def link(idens)
    idens.each do |iden| #also works with idens as a string containing just one iden?
      unless @links.include?(iden) or iden == @iden
	@links << iden
	update_times
      end
    end
  end
  
  def unlink(idens)
    idens.each do |iden| #also works with idens as a string containing just one iden?
      if @links.include?(iden)
	@links.delete(iden)
	update_times
      end    
    end
  end
  
  def comment=(c)
    @comment = c
    update_times
  end
  
  def title=(t)
    @title = t
    update_times
  end
end

class Web
  attr_reader :file, :thoughts
  def initialize(width, height, file = nil)
    if file==nil
      @thoughts = []
      @recent = []
      @selected = []
      @positions = []
    else
      
    end
    @width = width -5
    @height = height -5
  end
  
  def position(iden)
    @positions[@thoughts.find_index{|t| t.iden == iden}]
  end
  
  def add_thought(thought)
    @thoughts << thought
    @positions << Vector[(@width-100)*(rand-0.5),(@height-100)*(rand-0.5)]
    update_positions
  end
  
  def update_positions
    desiredSpacing = ((@width+@height)/@thoughts.size.to_f)**(1/3.0)
    minDim = @width > @height ? @height : @width
    potC = minDim*cos(PI/2*(minDim-50)/minDim)**2/sin(PI/2*(minDim-50)/minDim)
    chargeC = 1e7
    k = 1e2
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
      @positions.each_with_index do |pos,i|
	x = pos[0]
	y = pos[1]
	
	#force due to potential
	force = Vector[-sin(PI/2*x/w)/cos(PI/2*x/w)**2, -sin(PI/2*y/h)/cos(PI/2*y/h)**2]*potC
	
	#force due to springs
	@thoughts[i].links.each do |link|
	  pos2 = position(link)
	  r = pos2 - pos
	  force += r.unit*k*(r.length - restLength)
	end
	
	#force due to charges
	@positions.each do |pos2|
	  unless pos2 == pos #ignore itself
	    r = pos - pos2
	    force += r.unit*chargeC/r.length**2
	  end
	end

	forces << force
      end
      oldPos = @positions.dup
      oldVel = velocities.dup
      while true
	#update velocities
	velocities = oldVel.zip(forces).collect{|(v,f)| v*damping + f*timestep}
	#update positions
	@positions = oldPos.zip(velocities).collect{|(p,v)| p + v*timestep}
	#check to see if any are out of bounds
	if @positions.find{|p| p[0].abs > w or p[1].abs > h} == nil
	  break #exit loop if none are
	else
	  timestep /= 2.0 #if something's out of bounds, lower timestep and try again
	  count = 0
	end
      end 
      
      oldKE = ke
      ke = velocities.inject(0){|s,v| s + m*v.length**2}
      
      if oldKE > ke
	count += 1
      end
      #if it's been a while since anything went out of bounds and timestep<1, then slowly crank it back up
      if count == 10 and timestep < 1
	count = 0
	timestep *=1.0625
      end
print "KE: #{ke} timestep: #{timestep}\n"
    end while ke > timestep*@positions.size/10.0
  end
  
  def to_yaml
    
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
      pos = position(th.iden)
      th.links.each do |th2|
	pos2 = position(th2)
	#color the edges according to the following
	if @selected.include?(th.iden) and @selected.include?(th2)
	  color = "red" #verticies at both ends selected
	elsif @selected.include?(th.iden) or @selected.include?(th2)
	  color = "orange" #vertex at one end selected
	else
	  color = "black" #neither vertex selected
	end
	svg << %Q&<svg:line x1="#{pos[0]}" y1="#{pos[1]}" x2="#{pos2[0]}" y2="#{pos2[1]}" style="fill: none; stroke: #{color}; stroke-width: 10px;" />\n&
      end
    end
    #draw thought bubbles
    @thoughts.zip(@positions).each do |(t,p)|
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
	</svg:a>\
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
  
  def link_selected
    selectedThoughts = @selected.collect{|iden| @thoughts.find{|th| th.iden == iden}} #get array of the corresponding thoughts
    selectedThoughts.each{|th| th.link(@selected)}
    update_positions
  end

  def unlink_selected
    selectedThoughts = @selected.collect{|iden| @thoughts.find{|th| th.iden == iden}} #get array of the corresponding thoughts
    selectedThoughts.each{|th| th.unlink(@selected)}
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

get '/select/:iden' do
  iden = params[:iden]
  $web.toggle_select(iden)
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
  $web.add_thought(Thought.new(title,comment))
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
%html{:xmlns => "http://www.w3.org/1999/xhtml", "xml:lang" => "en", :lang => "en"}
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
          %input{:type=>'submit', :value=>'Save'}   
    %div{:id=>"control", :style=>"width: 300px; float: right; clear:right ; border-width: 0px 1px 1px 1px; border-style: solid; border-color: black;"} 
      %p{:style=>"text-align: center;"}
        %a{:href=>'/link'}="Link" 
        %a{:href=>'/unlink'}="Unlink" 
        %a{:href=>'/delete'}="Delete" 
        %a{:href=>'/deselect_all'}="Deselect All" 
        %a{:href=>'/undo'}="Undo" 
        %a{:href=>'/redo'}="Redo"
