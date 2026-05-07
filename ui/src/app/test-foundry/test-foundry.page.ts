import { Component, OnInit, OnDestroy } from '@angular/core';
import { Subscription } from 'rxjs';
import { ApiService, SamplePrompt, TestAgentResult } from '../services/api.service';
import { UseCaseService } from '../services/use-case.service';
import { DeviceService } from '../services/device.service';

@Component({
  selector: 'app-test-foundry',
  templateUrl: './test-foundry.page.html',
  styleUrls: ['./test-foundry.page.scss'],
  standalone: false,
})
export class TestFoundryPage implements OnInit, OnDestroy {
  prompts: SamplePrompt[] = [];
  selectedPrompt = '';
  result: TestAgentResult | null = null;
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
      this.selectedPrompt = '';
      this.loadPrompts();
    });
  }

  ngOnDestroy() { this.sub?.unsubscribe(); }

  loadPrompts() {
    this.api.getPrompts(this.uc.activeKey).subscribe({
      next: (map) => {
        this.prompts = [...(map.agent || []), ...(map.semantic || []), ...(map.keyword || [])];
        if (this.prompts.length) this.selectedPrompt = this.prompts[0].text;
      },
    });
  }

  run() {
    if (!this.selectedPrompt) return;
    this.loading = true;
    this.result = null;
    this.api.testFoundryDirect(this.selectedPrompt, this.uc.activeKey).subscribe({
      next: (r) => { this.result = r; this.loading = false; },
      error: (err) => {
        this.result = {
          ok: false, use_case: this.uc.activeKey, prompt: this.selectedPrompt,
          response: '', sources: [], errors: [err.message || 'Request failed'],
          duration_ms: 0, endpoint: '',
        };
        this.loading = false;
      },
    });
  }
}
