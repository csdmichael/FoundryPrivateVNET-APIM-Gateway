import { Injectable } from '@angular/core';
import { Platform } from '@ionic/angular';
import { BehaviorSubject, fromEvent } from 'rxjs';
import { debounceTime, startWith } from 'rxjs/operators';

export type DeviceType = 'mobile' | 'tablet' | 'desktop';

@Injectable({ providedIn: 'root' })
export class DeviceService {
  private _device$ = new BehaviorSubject<DeviceType>(this.detect());
  device$ = this._device$.asObservable();

  get current(): DeviceType { return this._device$.value; }

  constructor(private platform: Platform) {
    fromEvent(window, 'resize')
      .pipe(debounceTime(200), startWith(null))
      .subscribe(() => {
        const d = this.detect();
        if (d !== this._device$.value) this._device$.next(d);
      });
  }

  private detect(): DeviceType {
    const w = window.innerWidth;
    if (w < 768) return 'mobile';
    if (w < 1200) return 'tablet';
    return 'desktop';
  }

  get isMobile(): boolean { return this.current === 'mobile'; }
  get isTablet(): boolean { return this.current === 'tablet'; }
  get isDesktop(): boolean { return this.current === 'desktop'; }
}
