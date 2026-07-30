<!--
  Inline icon set. Hand-written 24x24 stroke paths rather than an icon package:
  the app needs nine glyphs, and bundling a library for that would outweigh the
  entire rest of the frontend.
-->
<script lang="ts">
  const PATHS = {
    plus: ['M12 5v14', 'M5 12h14'],
    check: ['M20 6 9 17l-5-5'],
    'check-all': ['M2 13l4 4 8-8', 'M12 15l3 3 7-8'],
    copy: [
      'M9 9h10a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V10a1 1 0 0 1 1-1Z',
      'M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1',
    ],
    export: ['M12 3v11', 'M8 10l4 4 4-4', 'M4 20h16'],
    trash: ['M4 7h16', 'M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2', 'M6 7l1 13h10l1-13'],
    pin: ['M12 16v6', 'M9 3h6l-1.2 6.2 2.7 2.7V14H7.5v-2.1l2.7-2.7L9 3Z'],
    x: ['M6 6l12 12', 'M18 6 6 18'],
    dots: ['M5 12h.01', 'M12 12h.01', 'M19 12h.01'],
    power: ['M12 3v9', 'M6.3 6.3a8 8 0 1 0 11.4 0'],
  } as const;

  type IconName = keyof typeof PATHS;

  let { name, size = 15 }: { name: IconName; size?: number } = $props();
</script>

<svg
  width={size}
  height={size}
  viewBox="0 0 24 24"
  fill="none"
  stroke="currentColor"
  stroke-width="2"
  stroke-linecap="round"
  stroke-linejoin="round"
  aria-hidden="true"
>
  {#each PATHS[name] as d (d)}
    <path {d} />
  {/each}
</svg>

<style>
  svg {
    display: block;
    flex: none;
  }
</style>
