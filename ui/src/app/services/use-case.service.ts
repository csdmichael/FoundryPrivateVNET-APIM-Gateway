import { Injectable } from '@angular/core';
import { BehaviorSubject } from 'rxjs';

export interface UseCaseInfo {
  key: string;
  label: string;
  docPrefix: string;
  fileFormat: string;  // 'txt' or 'pdf'
}

const USE_CASES: UseCaseInfo[] = [
  { key: 'tax_pdf_forms', label: 'Tax PDF Forms', docPrefix: 'TAX', fileFormat: 'pdf' },
  { key: 'eng_design_ppt', label: 'Engineering Design PPT', docPrefix: 'ENG', fileFormat: 'pptx' },
];

@Injectable({ providedIn: 'root' })
export class UseCaseService {
  private readonly STORAGE_KEY = 'active_use_case';

  readonly useCases = USE_CASES;
  private _active$ = new BehaviorSubject<UseCaseInfo>(this.loadSaved());

  /** Observable of the current use case — subscribe in components */
  active$ = this._active$.asObservable();

  /** Current value (synchronous) */
  get active(): UseCaseInfo { return this._active$.value; }
  get activeKey(): string { return this._active$.value.key; }

  switch(key: string) {
    const uc = this.useCases.find((u) => u.key === key);
    if (uc && uc.key !== this._active$.value.key) {
      this._active$.next(uc);
      try { localStorage.setItem(this.STORAGE_KEY, key); } catch {}
    }
  }

  private loadSaved(): UseCaseInfo {
    try {
      const saved = localStorage.getItem(this.STORAGE_KEY);
      const found = this.useCases.find((u) => u.key === saved);
      if (found) return found;
    } catch {}
    return USE_CASES[0];
  }
}
