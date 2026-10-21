'use client';
import { useState, type InputHTMLAttributes } from 'react';

// A password field with a Show / Hide button. The input keeps every prop it is given (name, autoComplete, aria) and
// stays the same element, so forms read it as before; only its type switches. The button never submits the form.
export function PasswordInput(props: Omit<InputHTMLAttributes<HTMLInputElement>, 'type'>) {
  const [show, setShow] = useState(false);
  const { className = 'input', ...rest } = props;
  return (
    <span className="pw">
      <input {...rest} className={className} type={show ? 'text' : 'password'} autoCapitalize="none" autoCorrect="off" spellCheck={false} />
      <button type="button" className="pw__btn" aria-pressed={show} aria-label={show ? 'Hide password' : 'Show password'}
        aria-controls={rest.id} onClick={() => setShow((s) => !s)} data-testid="password-toggle">{show ? 'Hide' : 'Show'}</button>
    </span>
  );
}
