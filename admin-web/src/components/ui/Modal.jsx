import { useEffect } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import clsx from 'clsx';

/** Centered modal with a scrim. Esc + backdrop click close (unless locked). */
export default function Modal({
  open,
  onClose,
  title,
  children,
  footer,
  size = 'md',
  locked = false,
}) {
  useEffect(() => {
    if (!open) return undefined;
    const onKey = (e) => {
      if (e.key === 'Escape' && !locked) onClose?.();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, locked, onClose]);

  if (!open) return null;

  const widths = { sm: 'max-w-sm', md: 'max-w-lg', lg: 'max-w-2xl' };

  return createPortal(
    <div className="fixed inset-0 z-[1100] flex items-center justify-center p-4">
      <div
        className="absolute inset-0 bg-black/40 backdrop-blur-sm"
        onClick={locked ? undefined : onClose}
      />
      <div
        className={clsx(
          'relative z-[1101] w-full rounded-card bg-card shadow-card border border-border/60',
          'max-h-[90vh] overflow-hidden flex flex-col',
          widths[size],
        )}
      >
        <div className="relative z-20 flex items-center justify-between border-b border-border/60 bg-card px-5 py-4">
          <h3 className="text-base font-semibold text-text-primary">{title}</h3>
          {!locked && (
            <button
              onClick={onClose}
              className="rounded-btn p-1 text-text-secondary hover:bg-border/50"
              aria-label="Close"
            >
              <X className="h-5 w-5" />
            </button>
          )}
        </div>
        <div className="relative z-0 overflow-y-auto px-5 py-4">{children}</div>
        {footer && (
          <div className="relative z-20 flex justify-end gap-2 border-t border-border/60 bg-card px-5 py-4">
            {footer}
          </div>
        )}
      </div>
    </div>,
    document.body,
  );
}
