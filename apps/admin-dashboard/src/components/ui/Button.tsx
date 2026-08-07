import type { ButtonHTMLAttributes } from 'react'

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'ghost'
  size?: 'sm' | 'md'
}

const VARIANT: Record<NonNullable<ButtonProps['variant']>, string> = {
  primary: 'bg-primary text-primary-foreground hover:bg-primary-pressed',
  secondary: 'bg-card text-foreground shadow-card hover:bg-card-nested',
  ghost: 'bg-transparent text-muted-foreground hover:bg-card-nested hover:text-foreground',
}

const SIZE: Record<NonNullable<ButtonProps['size']>, string> = {
  sm: 'h-8 px-3.5 text-xs',
  md: 'h-10 px-5 text-sm',
}

export function Button({ variant = 'primary', size = 'md', className = '', ...props }: ButtonProps) {
  return (
    <button
      className={`inline-flex shrink-0 items-center justify-center gap-1.5 rounded-full font-semibold tracking-tight transition-colors disabled:opacity-50 ${VARIANT[variant]} ${SIZE[size]} ${className}`}
      {...props}
    />
  )
}
