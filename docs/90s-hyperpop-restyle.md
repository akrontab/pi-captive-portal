# 90s-hyperpop-restyle — design spec (IMPLEMENTED)

> **Status:** built and deployed — see `www/index.html` (restyle in commit
> `66fa226`). Kept as the original spec of intent. The mushroom trip, the
> `0ld 1nt3rn3t` nixie counter with the goatse-at-420 egg, the floating friend
> faces, and the embedded guestbook are all live.

The color scheme should be load and bright and and even have some glitch core aesthetics incorperated. Some css tricks should be used to create a glitching effect on text and images. Images should be hard coded into the html and javascript using base 64 strings instead of serving seperate resources. I want to add a couple of easter eggs as well. The guestbook should be on this page Centered and very prominent under the easter eggs and click counter. The guestbook content will journal down the page. The page will be javascript and css heavy to get all the effects to work. No backend API calls should be made other than to get and post guestbook data.

I also want to page to be friendly to mobile browsers along with desktop browsers.


Easter eggs:

1. A whismical mushroom image that when clicked applies a psycedelic effect to the site for about 5 seconds
2. A 'click for 0ld 1nt3rn3t' link than when clicked increments a nixie tube looking counter underneth it and pops up old internet culture classics from the late 90s and early 2000s. Use the table below for which image to display on the number of clicks. The image will only be displayed for 3 seconds with a modal like window. The images can be found in the project's `./img/` path. Randomize the image that pops up for ever few clicks, which will also be random. The exception to this is on click 420 I want to display goatse. The html img tag and base64 data is already in the img folder as goatse.txt. Before adding the image data to the site and base64 make sure the image is shrunk down to something that fits in a 640x480 pixel box. maintain the height and width ratio of the original image when resizing.

Resolved questions:

- Music: **added.** A tap-to-start MIDI jukebox (Web Audio synth, no soundfont)
  plays a rotating set of 90s/early-2000s and game tracks — Sandstorm, DOOM E1M1,
  Green Hill Zone, What Is Love, All Star, Tetris, and more — each visitor
  starting on a random one. Autoplay isn't possible (browsers require a user
  gesture), so the ♪ button kicks it off.

Here are some references for glitchcore and hyperpop aesthetics that should be used:

https://aesthetics.fandom.com/wiki/Glitchcore
https://aesthetics.fandom.com/wiki/Hyperpop