import { cva, type VariantProps } from 'class-variance-authority'

export { default as Button } from './Button.vue'

export const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-full text-sm font-semibold transition-all duration-200 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:size-4 [&_svg]:shrink-0 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60 focus-visible:ring-offset-2 focus-visible:ring-offset-background active:scale-[0.98]",
  {
    variants: {
      variant: {
        default:
          'bg-primary text-primary-foreground shadow-[0_0_0_1px_rgba(58,160,255,.35),0_8px_30px_-8px_rgba(58,160,255,.7)] hover:brightness-110 hover:shadow-[0_0_0_1px_rgba(58,160,255,.5),0_12px_40px_-8px_rgba(58,160,255,.9)]',
        aurora:
          'text-white bg-[linear-gradient(110deg,var(--goat-accent),var(--goat-glow)_55%,var(--goat-accent2))] bg-[length:200%_100%] bg-left hover:bg-right shadow-[0_10px_40px_-10px_rgba(122,92,255,.8)] transition-[background-position,box-shadow,transform] duration-500',
        outline:
          'border border-border bg-transparent text-foreground hover:bg-white/5 hover:border-white/25',
        ghost: 'text-muted-foreground hover:text-foreground hover:bg-white/5',
        glass: 'glass text-foreground hover:bg-white/10',
        link: 'text-primary underline-offset-4 hover:underline rounded-none',
      },
      size: {
        default: 'h-10 px-5',
        sm: 'h-8 px-3.5 text-xs',
        lg: 'h-12 px-7 text-base',
        xl: 'h-14 px-9 text-lg',
        icon: 'size-10',
      },
    },
    defaultVariants: { variant: 'default', size: 'default' },
  },
)

export type ButtonVariants = VariantProps<typeof buttonVariants>
