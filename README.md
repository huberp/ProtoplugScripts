# ProtoplugScripts
Lua Scripts that can be used with https://www.osar.fr/protoplug/


## NoteFamilyFilter.Protoplug.lua

A simple midi utility which let's you decide which "note family" may pass it.
By note family I mean for instance all C notes of all octaves.

## KungFuAmplitude.lua

State: Beta

A Amplitude Shaper / Volume Pumper based on Catmul-Rom Splines.
I have applied Catmu-Rom Splines to get a smooth "processing" shape betwenn the the control points

What can it do?
* Go to GUI Tab
* There's a green rectangle
* double click in it to create you frist control point (red rectangle)
* double click on this rectangle - it will go away again
* you can as well drag a control point wherever you lie an drop it there...
* the white line depicts the catmul-rom spline computet through your points
* the blue line is the derived processing shape - tunred up side down for debugging purpose.
* Now let's play a note ... you see the volume is shaped accrding to your processing shape.
* Now let's go to parameters...
* You can set the sync frame, i.e. 1/64,...,1/8, 1/4...1/1
* And you can set the "power", i.e. how much influence the processor applies on you volume: 1- full, 0 - no affect






