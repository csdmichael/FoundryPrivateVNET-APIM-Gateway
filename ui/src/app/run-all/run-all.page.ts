import { Component, OnInit, OnDestroy } from '@angular/core';
import { Subscription, lastValueFrom } from 'rxjs';
import { catchError, of } from 'rxjs';
import {
  ApiService,
  SamplePrompt,
  SearchHealthResult,
  TestAgentResult,
  BotTestResult,
  AgentPackageInfo,
} from '../services/api.service';
import { UseCaseService } from '../services/use-case.service';
import { DeviceService } from '../services/device.service';

export type StepStatus = 'pending' | 'running' | 'pass' | 'fail' | 'skipped';

export interface StepResult {
  num: number;
  title: string;
  icon: string;
  status: StepStatus;
  durationMs: number | null;
  errors: string[];
  detail: any;
  _expanded?: boolean;
}

@Component({
  selector: 'app-run-all',
  templateUrl: './run-all.page.html',
  styleUrls: ['./run-all.page.scss'],
  standalone: false,
})
export class RunAllPage implements OnInit, OnDestroy {
  prompts: SamplePrompt[] = [];
  selectedPrompt = '';
  steps: StepResult[] = [];
  running = false;
  completedCount = 0;
  passedCount = 0;
  failedCount = 0;
  private sub?: Subscription;

  constructor(
    public api: ApiService,
    public uc: UseCaseService,
    public device: DeviceService,
  ) {}

  ngOnInit() {
    this.sub = this.uc.active$.subscribe(() => {
      this.resetSteps();
      this.loadPrompts();
    });
  }

  ngOnDestroy() { this.sub?.unsubscribe(); }

  loadPrompts() {
    this.api.getPrompts(this.uc.activeKey).subscribe({
      next: (map) => {
        this.prompts = [...(map.agent || []), ...(map.semantic || []), ...(map.keyword || [])];
        if (this.prompts.length && !this.selectedPrompt) {
          this.selectedPrompt = this.prompts[0].text;
        }
      },
    });
  }

  resetSteps() {
    this.steps = [
      { num: 1, title: 'AI Search Health', icon: 'search-outline', status: 'pending', durationMs: null, errors: [], detail: null },
      { num: 2, title: 'Foundry Agent (Direct)', icon: 'flash-outline', status: 'pending', durationMs: null, errors: [], detail: null },
      { num: 3, title: 'APIM Gateway', icon: 'cloud-outline', status: 'pending', durationMs: null, errors: [], detail: null },
      { num: 4, title: 'Bot Service', icon: 'chatbubbles-outline', status: 'pending', durationMs: null, errors: [], detail: null },
      { num: 5, title: 'Agent Package', icon: 'download-outline', status: 'pending', durationMs: null, errors: [], detail: null },
    ];
    this.completedCount = 0;
    this.passedCount = 0;
    this.failedCount = 0;
    this.running = false;
  }

  async runAll() {
    if (!this.selectedPrompt) return;
    this.resetSteps();
    this.running = true;

    // Step 1: AI Search Health
    await this.runStep(0, async () => {
      const r = await lastValueFrom(this.api.testSearchHealth(this.uc.activeKey).pipe(
        catchError(err => of({ ok: false, errors: [err.message || 'Request failed'], duration_ms: 0 } as any))
      ));
      this.steps[0].durationMs = r.duration_ms;
      this.steps[0].errors = r.errors || [];
      this.steps[0].detail = r;
      return r.ok;
    });

    // Step 2: Foundry Direct
    await this.runStep(1, async () => {
      const r = await lastValueFrom(this.api.testFoundryDirect(this.selectedPrompt, this.uc.activeKey).pipe(
        catchError(err => of({ ok: false, errors: [err.message || 'Request failed'], duration_ms: 0, prompt: this.selectedPrompt, response: '', endpoint: '', use_case: '', sources: [] } as TestAgentResult))
      ));
      this.steps[1].durationMs = r.duration_ms;
      this.steps[1].errors = r.errors || [];
      this.steps[1].detail = r;
      return r.ok;
    });

    // Step 3: APIM Gateway
    await this.runStep(2, async () => {
      const r = await lastValueFrom(this.api.testApim(this.selectedPrompt, this.uc.activeKey).pipe(
        catchError(err => of({ ok: false, errors: [err.message || 'Request failed'], duration_ms: 0, prompt: this.selectedPrompt, response: '', endpoint: '', use_case: '', sources: [] } as TestAgentResult))
      ));
      this.steps[2].durationMs = r.duration_ms;
      this.steps[2].errors = r.errors || [];
      this.steps[2].detail = r;
      return r.ok;
    });

    // Step 4: Bot Service
    await this.runStep(3, async () => {
      const r = await lastValueFrom(this.api.testBotService(this.selectedPrompt, this.uc.activeKey).pipe(
        catchError(err => of({ ok: false, errors: [err.message || 'Request failed'], duration_ms: 0, prompt: this.selectedPrompt, response: '', bot_endpoint: '', bot_healthy: false, apim_chat_url: '', use_case: '', sources: [] } as BotTestResult))
      ));
      this.steps[3].durationMs = r.duration_ms;
      this.steps[3].errors = r.errors || [];
      this.steps[3].detail = r;
      return r.ok;
    });

    // Step 5: Agent Package
    await this.runStep(4, async () => {
      const r = await lastValueFrom(this.api.getAgentPackages(this.uc.activeKey).pipe(
        catchError(err => of({ package_exists: false, files: [], agent_name: '', use_case: this.uc.activeKey, package_path: null, teams_dev_portal_url: '' } as AgentPackageInfo))
      ));
      this.steps[4].durationMs = null;
      this.steps[4].detail = r;
      const ok = r.files.length > 0;
      if (!ok) this.steps[4].errors = ['No package files found'];
      return ok;
    });

    this.running = false;
  }

  private async runStep(index: number, fn: () => Promise<boolean>) {
    this.steps[index].status = 'running';
    try {
      const ok = await fn();
      this.steps[index].status = ok ? 'pass' : 'fail';
    } catch (err: any) {
      this.steps[index].status = 'fail';
      this.steps[index].errors.push(err.message || 'Unexpected error');
    }
    this.completedCount++;
    if (this.steps[index].status === 'pass') this.passedCount++;
    else this.failedCount++;
  }

  get totalDurationMs(): number {
    return this.steps.reduce((sum, s) => sum + (s.durationMs || 0), 0);
  }

  statusIcon(s: StepStatus): string {
    switch (s) {
      case 'pass': return 'checkmark-circle';
      case 'fail': return 'close-circle';
      case 'running': return 'sync-outline';
      default: return 'ellipse-outline';
    }
  }

  statusColor(s: StepStatus): string {
    switch (s) {
      case 'pass': return 'success';
      case 'fail': return 'danger';
      case 'running': return 'primary';
      default: return 'medium';
    }
  }
}
