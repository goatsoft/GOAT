import { cva, type VariantProps } from 'class-variance-authority'

export { default as Card } from './Card.vue'

export const cardVariants = cva('relative rounded-2xl text-card-foreground transition-colors', {
  variants: {
    variant: {
      default: 'bg-card ring-hair',
      glass: 'glass',
      glow: 'bg-card ring-hair before:pointer-events-none before:absolute before:inset-0 before:rounded-2xl before:bg-[radial-gradient(60%_50%_at_50%_0%,rgba(58,160,255,.14),transparent_70%)]',
      outline: 'border border-border bg-transparent',
    },
    padding: {
      none: 'p-0',
      sm: 'p-4',
      md: 'p-6',
      lg: 'p-8',
    },
  },
  defaultVariants: { variant: 'default', padding: 'md' },
})

export type CardVariants = VariantProps<typeof cardVariants>
