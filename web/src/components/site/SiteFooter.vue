<script setup lang="ts">
const site = useSite()
</script>

<template>
  <footer class="relative border-t sm:mt-32 border-border/60">
    <div class="mx-auto grid max-w-6xl gap-8 px-6 py-10 sm:gap-10 sm:py-14 md:grid-cols-[1.4fr_1fr_1fr_1fr]">
      <div>
        <div class="flex items-center gap-2.5 font-semibold">
          <img :src="asset('img/goat-dark.webp')" alt="" class="size-8 drop-shadow-[0_4px_14px_rgba(122,92,255,.5)]" />
          <span class="text-brand text-lg font-bold tracking-tight">GOAT</span>
        </div>
        <p class="mt-3 max-w-xs text-sm text-muted-foreground text-pretty">
          Help make local AI practical on the Mac. Contribute code, improve the docs, test compatibility or support ongoing maintenance.
        </p>
        <p class="mt-3 max-w-xs text-xs leading-relaxed text-muted-foreground">Code, docs and examples: MIT. Artwork and branding have separate terms.</p>
        <p class="mt-4 font-mono text-xs text-muted-foreground/70">{{ site.requirements }}</p>
      </div>

      <div>
        <h4 class="text-sm font-semibold">Product</h4>
        <ul class="mt-3 space-y-2 text-sm text-muted-foreground">
          <li><RouterLink to="/#features" class="hover:text-foreground">Features</RouterLink></li>
          <li><RouterLink to="/#privacy" class="hover:text-foreground">Privacy and control</RouterLink></li>
          <li><RouterLink to="/#themes" class="hover:text-foreground">Themes</RouterLink></li>
          <li><a :href="site.primaryHref" class="hover:text-foreground">{{ site.releaseAvailable ? 'Download' : 'Get started' }}</a></li>
        </ul>
      </div>

      <div>
        <h4 class="text-sm font-semibold">Developers</h4>
        <ul class="mt-3 space-y-2 text-sm text-muted-foreground">
          <li><a :href="site.repo" class="hover:text-foreground">GitHub</a></li>
          <li><a :href="site.docs" class="hover:text-foreground">Documentation</a></li>
          <li><a :href="site.doc('ENGINES')" class="hover:text-foreground">Engine contract</a></li>
          <li><a :href="site.doc('THEMES')" class="hover:text-foreground">Theme format</a></li>
        </ul>
      </div>

      <div>
        <h4 class="text-sm font-semibold">Community</h4>
        <ul class="mt-3 space-y-2 text-sm text-muted-foreground">
          <li><a :href="site.sponsor" class="hover:text-foreground">Sponsor GOAT</a></li>
          <li><a href="mailto:baa@goatapp.dev" class="hover:text-foreground">Contact GOAT</a></li>
          <li><a :href="`${site.repo}/issues`" class="hover:text-foreground">Issues</a></li>
          <li><a :href="site.doc('Contributing')" class="hover:text-foreground">Contributing</a></li>
          <li><a :href="`${site.repo}/blob/main/SECURITY.md`" class="hover:text-foreground">Security</a></li>
          <li><a :href="`${site.repo}/blob/main/CODE_OF_CONDUCT.md`" class="hover:text-foreground">Code of conduct</a></li>
        </ul>
      </div>
    </div>
    <div class="mx-auto flex max-w-6xl flex-col items-start justify-between gap-3 border-t border-border/60 px-6 py-6 text-xs text-muted-foreground/70 md:flex-row md:items-center">
      <span class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <span>© {{ site.year }} GOAT contributors.</span>
        <DocDialog doc="license" title="MIT licence"><button type="button" class="hover:text-foreground">MIT licence</button></DocDialog>
        <span aria-hidden="true">·</span>
        <DocDialog doc="license-art" hue="violet"><button type="button" class="hover:text-foreground">Artwork licence</button></DocDialog>
        <span aria-hidden="true">·</span>
        <DocDialog doc="third-party-notices" hue="blue"><button type="button" class="hover:text-foreground">Third-party notices</button></DocDialog>
        <span aria-hidden="true">·</span>
        <DocDialog doc="privacy" hue="indigo"><button type="button" class="hover:text-foreground">Privacy</button></DocDialog>
      </span>
      <span>Not affiliated with Apple. macOS is a trademark of Apple Inc.</span>
    </div>
  </footer>
</template>
