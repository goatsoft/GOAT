import { cva, type VariantProps } from 'class-variance-authority'

export { default as Badge } from './Badge.vue'

export const badgeVariants = cva(
  'inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium tracking-wide transition-colors [&_svg]:size-3.5',
  {
    variants: {
      variant: {
        default: 'border-transparent bg-primary/15 text-primary',
        violet: 'border-transparent bg-goat-accent2/15 text-[#d9a3ff]',
        outline: 'border-border text-muted-foreground',
        glass: 'glass text-foreground',
        success: 'border-transparent bg-emerald-400/15 text-emerald-300',
      },
    },
    defaultVariants: { variant: 'default' },
  },
)

export type BadgeVariants = VariantProps<typeof badgeVariants>
