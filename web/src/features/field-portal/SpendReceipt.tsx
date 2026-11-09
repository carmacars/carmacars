'use client';
import { useState } from 'react';
import { Msg, PhotoPick, sendWork, useRun } from './Steps';

// A receipt added after the money was recorded (0930): the To do closes once it is in.
export function SpendReceipt({ id }: { id: string }) {
  const [file, setFile] = useState<File | null>(null);
  const { pending, msg, run } = useRun();
  return (
    <div className="fp-form" data-testid={`receipt-${id}`}>
      <PhotoPick file={file} set={setFile} label="Photo of the receipt" pdf />
      {file && <button type="button" className="btn btn--primary fd-wide" disabled={pending} onClick={() => run(() => sendWork('spend_receipt', { id }, file), 'Receipt added.')}>{pending ? 'Sending' : 'Add the receipt'}</button>}
      <Msg m={msg} />
    </div>
  );
}
