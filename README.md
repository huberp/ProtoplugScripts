# ProtoplugScripts
Lua Scripts that can be used with https://www.osar.fr/protoplug/
Please go and first install protoplug on your computer and become familiar with how to use it.

## NoteFamilyFilter.Protoplug.lua

A simple midi utility which let's you decide which "note family" may pass it.
By note family I mean for instance all C notes of all octaves.

## AmplitudeKungFu.lua

### The Basics

State: Alpha

A Amplitude Shaper / Volume Pumper based on Catmull-Rom Splines.
I have applied Catmull-Rom Splines to get a smooth "processing" shape between an arbitrary number of control points that the user can add/remove.

### How to install
* Add a protoplug instance to your project
* Open it
* Go to the "code tab"
* Open an brwoser and go to this url to get the script: https://raw.githubusercontent.com/huberp/ProtoplugScripts/main/KungFuAmplitude.lua
* Copy all the text - On windows Strg-a + Strg-C
* Switch to protoplug again. Click in the code panel.
* Paste the Code - On windos Strg-v
* In the protoplug menu go to "build" > "Compile now" to compile the script
* Now you're ready to switch to the Gui Tab and add control points

### What can AmplitudeKungFu do?
* Go to GUI Tab of protoplug
* There's a green rectangle
* double click in it to create you frist control point (a red rectangle)
* double click on this rectangle - it will go away again
* you can as well drag a control point (red rectangle) wherever you lie an drop it there...
* the white line depicts the catmul-rom spline computet through your points
* the blue line is the derived processing shape - tunred up side down for debugging purpose.
* Now let's play a note ... you see the volume is shaped accrding to your processing shape.
* Now let's go to parameters...
* You can set the sync frame, i.e. 1/64,...,1/8, 1/4...1/1
* And you can set the "power", i.e. how much influence the processor applies on you volume: 1- full, 0 - no affect
* Now play some notes, i.e. by using your keyboard or run a sequence, AmplitudeKungFu will shape the volume and will show the result with a "green" sample view.

### Recent Changes and upcoming

#### Alpha 0.7 (up coming)
* I will do a version using "Centripetal Catmull-Rom Spline" which don't suffer from the "defects" of the current impl. It can even have "loops" for some settings of control points.
* Do more modularization, i.e. add "eventing" to wire up components in a more clear and modular way.

#### Alpha 0.6
* Many performance improvements regarding algorithms and on how to use lua in an performant way. It can now survive tempo automatization. before it simply was to inefficient.
* Added a background grid splitting the visible frame in 1/8 and 1/8 dotted lines for orientation
* Made the processing curve (blue rectangles) stay in limits. The catmull-rom spline in itself has certain problems in that it "overshots", i.e. goes lower than 0 or hogher than 1 if you for certain control point settings. The derived processing curve will always be in the bounds.
* For Devs
  * Spend some time on Modularization: First shot is to build a number of "Renderer" Objects where each renderer is responsible for a certain aspect of the GUI


#### Alpha 0.5
* Ramped up the plugin and wrote the code to do the sample accurate sync
* Added the first version of the Catmull-Rom splines








