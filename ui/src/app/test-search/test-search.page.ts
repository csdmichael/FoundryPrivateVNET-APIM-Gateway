import { Component, OnInit, OnDestroy } from '@angular/core';
import { Subscription } from 'rxjs';
import { ApiService, SearchHealthResult } from '../services/api.service';
import { UseCaseService } from '../services/use-case.service';
import { DeviceService } from '../services/device.service';

@Component({
  selector: 'app-test-search',
  templateUrl: './test-search.page.html',
  styleUrls: ['./test-search.page.scss'],
  standalone: false,
})
export class TestSearchPage implements OnInit, OnDestroy {
  result: SearchHealthResult | null = null;
  loading = false;
  private sub?: Subscription;

  constructor(
    public api: ApiService,
    public uc: UseCaseService,
    public device: DeviceService,
  ) {}

  ngOnInit() {
    this.sub = this.uc.active$.subscribe(() => {
      this.result = null;
    });
  }

  ngOnDestroy() {
    this.sub?.unsubscribe();
  }

  run() {
    this.loading = true;
    this.result = null;
    this.api.testSearchHealth(this.uc.activeKey).subscribe({
      next: (r) => { this.result = r; this.loading = false; },
      error: (err) => {
        this.result = {
          ok: false, use_case: this.uc.activeKey, index_name: '', search_endpoint: '',
          document_count: 0, storage_size_bytes: 0, fields: [],
          errors: [err.message || 'Request failed'], duration_ms: 0,
        };
        this.loading = false;
      },
    });
  }

  formatBytes(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
  }
}
