import { Component, Input } from '@angular/core';

@Component({
  selector: 'app-test-result-card',
  standalone: false,
  template: `
    <ion-card [class.result-ok]="ok === true" [class.result-fail]="ok === false">
      <ion-card-header (click)="expanded = !expanded" style="cursor: pointer">
        <ion-card-title class="result-header">
          <ion-icon [name]="ok === null ? 'hourglass-outline' : ok ? 'checkmark-circle' : 'close-circle'"
                    [color]="ok === null ? 'medium' : ok ? 'success' : 'danger'"></ion-icon>
          <span>{{ title }}</span>
          <ion-badge *ngIf="durationMs !== null" color="medium" class="duration-badge">{{ durationMs }}ms</ion-badge>
          <ion-icon [name]="expanded ? 'chevron-up' : 'chevron-down'" class="expand-icon"></ion-icon>
        </ion-card-title>
      </ion-card-header>

      <ion-card-content *ngIf="expanded">
        <!-- KPI row -->
        <div class="kpi-row" *ngIf="ok !== null">
          <app-kpi-badge [value]="ok ? 'PASS' : 'FAIL'" label="Status" [color]="ok ? 'success' : 'danger'"></app-kpi-badge>
          <app-kpi-badge *ngIf="durationMs !== null" [value]="durationMs + 'ms'" label="Latency"
            [color]="durationMs! < 3000 ? 'success' : durationMs! < 10000 ? 'warning' : 'danger'"></app-kpi-badge>
        </div>

        <!-- Errors -->
        <div *ngIf="errors.length" class="errors-section">
          <div class="errors-header">
            <ion-text color="danger"><strong>Errors ({{ errors.length }}):</strong></ion-text>
            <ion-button fill="clear" size="small" (click)="copyErrors($event)" class="copy-btn">
              <ion-icon [name]="copied ? 'checkmark-outline' : 'copy-outline'" slot="start"></ion-icon>
              {{ copied ? 'Copied' : 'Copy' }}
            </ion-button>
          </div>
          <ul>
            <li *ngFor="let e of errors" class="error-item">{{ e }}</li>
          </ul>
        </div>

        <!-- Endpoint -->
        <div *ngIf="endpoint" class="detail-row">
          <strong>Endpoint:</strong> <code>{{ endpoint }}</code>
        </div>

        <!-- Content projection for custom details -->
        <ng-content></ng-content>
      </ion-card-content>
    </ion-card>
  `,
  styles: [`
    .result-ok { border-left: 4px solid var(--ion-color-success); }
    .result-fail { border-left: 4px solid var(--ion-color-danger); }
    .result-header {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 1rem;
      span { flex: 1; }
    }
    .expand-icon { font-size: 18px; color: var(--ion-color-medium); }
    .duration-badge { font-size: 0.75rem; }
    .kpi-row { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 12px; }
    .errors-section {
      background: rgba(var(--ion-color-danger-rgb), 0.06);
      border-radius: 6px;
      padding: 8px 12px;
      margin-bottom: 8px;
      ul { margin: 4px 0 0; padding-left: 18px; }
      .error-item { font-size: 0.85rem; color: var(--ion-color-danger-shade); margin-bottom: 4px; }
    }
    .errors-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .copy-btn {
      --padding-start: 4px;
      --padding-end: 4px;
      font-size: 0.75rem;
      height: 28px;
    }
    .detail-row { font-size: 0.85rem; margin-bottom: 6px; code { font-size: 0.8rem; background: var(--ion-color-light); padding: 2px 6px; border-radius: 4px; } }
  `]
})
export class TestResultCardComponent {
  @Input() title = '';
  @Input() ok: boolean | null = null;
  @Input() durationMs: number | null = null;
  @Input() errors: string[] = [];
  @Input() endpoint = '';

  expanded = false;
  copied = false;

  copyErrors(event: Event) {
    event.stopPropagation();
    const text = `[${this.title}]\n` + this.errors.join('\n');
    navigator.clipboard.writeText(text).then(() => {
      this.copied = true;
      setTimeout(() => this.copied = false, 2000);
    });
  }
}
