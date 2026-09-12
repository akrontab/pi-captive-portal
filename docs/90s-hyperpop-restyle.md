# 90s-hyperpop-restyle — design spec (NOT YET IMPLEMENTED)

The color scheme should be load and bright and and even have some glitch core aesthetics incorperated. Some css tricks should be used to create a glitching effect on text and images. Images should be hard coded into the html and javascript using base 64 strings instead of serving seperate resources. I want to add a couple of easter eggs as well. The guestbook should be on this page Centered and very prominent under the easter eggs and click counter. The guestbook content will journal down the page. The page will be javascript and css heavy to get all the effects to work. No backend API calls should be made other than to get and post guestbook data.

Easter eggs:

1. A whismical mushroom image that when clicked applies a psycedelic effect to the site for about 5 seconds
2. A 'click for 0ld 1nt3rn3t' link than when clicked increments a nixie tube looking counter underneth it and pops up old internet culture classics from the late 90s and early 2000s. Use the table below for which image to display on the number of clicks. The image will only be displayed for 3 seconds with a modal like window. The images can be found in the project's `./img/` path. Randomize the image that pops up for ever few clicks, which will also be random. The exception to this is on click 420 I want to display goatse. The html img tag and base64 data is already in the img folder as goatse.txt. Before adding the image data to the site and base64 make sure the image is shrunk down to something that fits in a 640x480 pixel box. maintain the height and width ratio of the original image when resizing.

Open questions:

- Should we add some music to auto play when the user hits the portal page? I'm thinking some 16 bit music from sonic the hedgehog. Maybe Sandstorm by DaRude?

Here are some references for glitchcore and hyperpop aesthetics that should be used:

https://aesthetics.fandom.com/wiki/Glitchcore
https://aesthetics.fandom.com/wiki/Hyperpop