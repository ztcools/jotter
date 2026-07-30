<!--
  The mascot: a sitting anime cat holding a notebook, drawn as inline SVG and
  animated with CSS keyframes.

  Hand-authored rather than an imported asset. A downloaded illustration would
  add a licence to honour and a raster/Lottie payload to ship, and it could not
  react to state — here the ears, tail, eyes and notebook all belong to the same
  document as the styles that move them, which is what makes `pressed` and
  `open` feel like the cat noticing you rather than a sprite swap.

  Everything is one path set in a 100x100 viewBox, so it stays crisp at any DPI
  and costs no network request.
-->
<script lang="ts">
  let { pressed = false, open = false }: { pressed?: boolean; open?: boolean } = $props();
</script>

<svg class="cat" class:pressed class:open viewBox="0 0 100 100" aria-hidden="true">
  <defs>
    <linearGradient id="fur" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fffaf3" />
      <stop offset="1" stop-color="#ffe9d2" />
    </linearGradient>
    <linearGradient id="book" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="var(--accent)" />
      <stop offset="1" stop-color="var(--accent-2)" />
    </linearGradient>
  </defs>

  <!-- Contact shadow. Squashes in step with the body so the cat reads as
       resting on the desktop rather than pasted onto it. -->
  <ellipse class="drop" cx="50" cy="91.5" rx="25" ry="4.2" />

  <g class="cat-body">
    <!-- Tail, behind everything: same stroke colour as the fur so the join at
         the hip is invisible. -->
    <path class="tail" d="M69 78C83 79 90 68 85 57" />

    <path class="fur body" d="M50 45c14 0 25 13 25 27 0 9-11 14-25 14s-25-5-25-14c0-14 11-27 25-27Z" />

    <g class="head">
      <!-- Ear and its inner shell are grouped so one transform moves both. -->
      <g class="ear ear-l">
        <path class="fur shell" d="M30 23 25 6l20 10Z" />
        <path class="ear-in" d="M31 20.5 28.6 11l11 5.4Z" />
      </g>
      <g class="ear ear-r">
        <path class="fur shell" d="M70 23 75 6l-20 10Z" />
        <path class="ear-in" d="M69 20.5 71.4 11l-11 5.4Z" />
      </g>

      <ellipse class="fur" cx="50" cy="41" rx="27.5" ry="24.5" />

      <path class="whisker" d="M17.5 43.5 30 45.5M17.5 51 30 50.5" />
      <path class="whisker" d="M82.5 43.5 70 45.5M82.5 51 70 50.5" />

      <ellipse class="blush" cx="27.5" cy="52" rx="5.6" ry="3" />
      <ellipse class="blush" cx="72.5" cy="52" rx="5.6" ry="3" />

      <g class="eye eye-l">
        <ellipse class="iris" cx="39" cy="43" rx="6.2" ry="7.6" />
        <circle class="spark" cx="41.2" cy="39.6" r="2.3" />
        <circle class="spark dim" cx="36.6" cy="46.4" r="1.2" />
      </g>
      <g class="eye eye-r">
        <ellipse class="iris" cx="61" cy="43" rx="6.2" ry="7.6" />
        <circle class="spark" cx="63.2" cy="39.6" r="2.3" />
        <circle class="spark dim" cx="58.6" cy="46.4" r="1.2" />
      </g>

      <path class="nose" d="M47.6 49.4c1.3-1.5 3.5-1.5 4.8 0-1.3 2.4-3.5 2.4-4.8 0Z" />
      <path class="mouth" d="M45.8 53.4c1.4 2.6 2.8 2.6 4.2 0 1.4 2.6 2.8 2.6 4.2 0" />
    </g>

    <!-- The notebook it is holding: the app's own subject, and the reason the
         silhouette reads as "note taking" and not just "a cat". -->
    <g class="note">
      <rect x="37" y="66" width="26" height="17" rx="3.5" fill="url(#book)" />
      <path class="ruled" d="M41.5 71.5h12M41.5 76.5h9" />
      <path class="check" d="M55 71.8l2.2 2.4 4-5" />
    </g>

    <ellipse class="fur paw" cx="38" cy="83.5" rx="7.2" ry="5.2" />
    <ellipse class="fur paw" cx="62" cy="83.5" rx="7.2" ry="5.2" />
  </g>
</svg>

<style>
  .cat {
    display: block;
    width: 100%;
    height: 100%;
    overflow: visible;
    /* The window is transparent, so the cat needs its own shadow to separate
       from whatever wallpaper is behind it. */
    filter: drop-shadow(0 5px 10px rgba(40, 30, 90, 0.28));
    transition: transform var(--dur-fast) var(--ease);
  }

  .fur {
    fill: url(#fur);
    stroke: #e8c9a8;
    stroke-width: 1.6;
  }

  .shell {
    stroke-width: 3.4;
    stroke-linejoin: round; /* rounds the ear tips without a second path */
  }

  .ear-in {
    fill: #ffb3c7;
    stroke: #ffb3c7;
    stroke-width: 2.6;
    stroke-linejoin: round;
  }

  .paw {
    stroke-width: 1.4;
  }

  .tail {
    fill: none;
    stroke: #ffeedc;
    stroke-width: 7.5;
    stroke-linecap: round;
  }

  .drop {
    fill: rgba(35, 25, 70, 0.16);
  }

  .iris {
    fill: #3a3560;
  }

  .spark {
    fill: #fff;
  }

  .spark.dim {
    fill: rgba(255, 255, 255, 0.65);
  }

  .blush {
    fill: #ffb3c7;
    opacity: 0.6;
  }

  .nose {
    fill: #ff9fb6;
  }

  .mouth {
    fill: none;
    stroke: #7c6a86;
    stroke-width: 1.5;
    stroke-linecap: round;
  }

  .whisker {
    fill: none;
    stroke: rgba(124, 106, 134, 0.5);
    stroke-width: 1.4;
    stroke-linecap: round;
  }

  .ruled {
    fill: none;
    stroke: rgba(255, 255, 255, 0.75);
    stroke-width: 1.8;
    stroke-linecap: round;
  }

  /* Ticked only while the notebook window is open — the cat is "on it". */
  .check {
    fill: none;
    stroke: #fff;
    stroke-width: 2.2;
    stroke-linecap: round;
    stroke-linejoin: round;
    opacity: 0;
    transition: opacity var(--dur) var(--ease);
  }

  .open .check {
    opacity: 1;
  }

  .open .ruled {
    opacity: 0.45;
  }

  /* ------------------------------------------------------------- animation
     Transforms use viewBox coordinates: Chromium's default `transform-box` for
     SVG elements is `view-box`, so an origin like `68px 78px` is the tail root
     regardless of how large the window renders. Durations are deliberately
     co-prime-ish so the parts never fall into lockstep and start looking
     mechanical. */

  .cat-body {
    animation: float 3.4s var(--ease) infinite alternate;
  }

  .body {
    transform-origin: 50px 86px;
    animation: breathe 2.9s var(--ease) infinite alternate;
  }

  .drop {
    transform-origin: 50px 91.5px;
    animation: shade 2.9s var(--ease) infinite alternate;
  }

  .head {
    transform-origin: 50px 63px;
    animation: nod 5.3s var(--ease) infinite alternate;
  }

  .tail {
    transform-origin: 69px 78px;
    animation: wag 2.3s var(--ease) infinite alternate;
  }

  .open .tail {
    animation-duration: 1.05s; /* pleased to be useful */
  }

  .ear-l {
    transform-origin: 32px 23px;
    animation: twitch-l 6.7s var(--ease) infinite;
  }

  .ear-r {
    transform-origin: 68px 23px;
    animation: twitch-r 8.3s var(--ease) infinite;
  }

  .eye-l {
    transform-origin: 39px 43px;
  }

  .eye-r {
    transform-origin: 61px 43px;
  }

  .eye {
    animation: blink 5.9s var(--ease) infinite;
  }

  @keyframes float {
    from {
      transform: translateY(0.6px);
    }
    to {
      transform: translateY(-1.8px);
    }
  }

  @keyframes breathe {
    from {
      transform: scale(1, 1);
    }
    to {
      transform: scale(1.025, 0.975);
    }
  }

  @keyframes shade {
    from {
      transform: scale(1, 1);
      opacity: 1;
    }
    to {
      transform: scale(0.94, 0.9);
      opacity: 0.82;
    }
  }

  @keyframes nod {
    from {
      transform: rotate(-2.2deg);
    }
    to {
      transform: rotate(2.2deg);
    }
  }

  @keyframes wag {
    from {
      transform: rotate(-11deg);
    }
    to {
      transform: rotate(13deg);
    }
  }

  /* One flick per cycle, held still the rest of the time: a continuous
     ear rotation looks like a glitch, a single twitch looks alive. */
  @keyframes twitch-l {
    0%,
    8%,
    100% {
      transform: rotate(0deg);
    }
    3% {
      transform: rotate(-9deg);
    }
    5.5% {
      transform: rotate(3deg);
    }
  }

  @keyframes twitch-r {
    0%,
    46%,
    100% {
      transform: rotate(0deg);
    }
    41% {
      transform: rotate(9deg);
    }
    43.5% {
      transform: rotate(-3deg);
    }
  }

  @keyframes blink {
    0%,
    93%,
    100% {
      transform: scaleY(1);
    }
    95.5% {
      transform: scaleY(0.06);
    }
  }

  /* --------------------------------------------------------------- pressed */

  .cat.pressed {
    transform: translateY(2px) scale(0.93, 0.89);
  }

  /* Squints while held: the squash alone reads as a button, the squint reads as
     a cat being squished. */
  .cat.pressed .eye {
    animation: none;
    transform: scaleY(0.3);
  }

  .cat.pressed .drop {
    animation: none;
    transform: scale(1.06, 1.1);
    opacity: 0.7;
  }

  /* `app.css` clamps every animation to 1ms under reduced motion, which for an
     infinite alternate keyframe means a flicker rather than calm. Stop them
     outright instead. */
  @media (prefers-reduced-motion: reduce) {
    .cat *,
    .cat {
      animation: none !important;
      transition: none !important;
    }
  }
</style>
