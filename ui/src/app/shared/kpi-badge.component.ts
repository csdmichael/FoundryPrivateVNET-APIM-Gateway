import { Component, Input } from '@angular/core';

@Component({
  selector: 'app-kpi-badge',
  standalone: false,
  template: `
    <div class="kpi" [class.kpi-success]="color === 'success'" [class.kpi-danger]="color === 'danger'" [class.kpi-warning]="color === 'warning'">
      <div class="kpi-value">{{ value }}</div>
      <div class="kpi-label">{{ label }}</div>
    </div>
  `,
  styles: [`
    .kpi {
      display: inline-flex;
      flex-direction: column;
      align-items: center;
      padding: 8px 16px;
      border-radius: 8px;
      background: var(--ion-color-light);
      min-width: 80px;
    }
    .kpi-value { font-size: 1.4rem; font-weight: 700; }
    .kpi-label { font-size: 0.72rem; color: var(--ion-color-medium); text-transform: uppercase; letter-spacing: 0.5px; }
    .kpi-success .kpi-value { color: var(--ion-color-success); }
    .kpi-danger .kpi-value { color: var(--ion-color-danger); }
    .kpi-warning .kpi-value { color: var(--ion-color-warning); }
  `]
})
export class KpiBadgeComponent {
  @Input() value: string | number = '';
  @Input() label = '';
  @Input() color: 'success' | 'danger' | 'warning' | '' = '';
}
