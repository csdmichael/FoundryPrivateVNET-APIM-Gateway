import { Component, OnInit, OnDestroy } from '@angular/core';
import { Subscription } from 'rxjs';
import { ApiService, AgentPackageInfo, AgentPackageBuildResult } from '../services/api.service';
import { UseCaseService } from '../services/use-case.service';
import { DeviceService } from '../services/device.service';

@Component({
  selector: 'app-agent-package',
  templateUrl: './agent-package.page.html',
  styleUrls: ['./agent-package.page.scss'],
  standalone: false,
})
export class AgentPackagePage implements OnInit, OnDestroy {
  info: AgentPackageInfo | null = null;
  buildResult: AgentPackageBuildResult | null = null;
  loadingInfo = false;
  building = false;
  error = '';
  private sub?: Subscription;

  constructor(
    public api: ApiService,
    public uc: UseCaseService,
    public device: DeviceService,
  ) {}

  ngOnInit() {
    this.sub = this.uc.active$.subscribe(() => {
      this.info = null;
      this.buildResult = null;
      this.error = '';
      this.loadInfo();
    });
  }

  ngOnDestroy() { this.sub?.unsubscribe(); }

  loadInfo() {
    this.loadingInfo = true;
    this.api.getAgentPackages(this.uc.activeKey).subscribe({
      next: (r) => { this.info = r; this.loadingInfo = false; },
      error: (err) => { this.error = err.message; this.loadingInfo = false; },
    });
  }

  build() {
    this.building = true;
    this.buildResult = null;
    this.api.buildAgentPackage(this.uc.activeKey).subscribe({
      next: (r) => {
        this.buildResult = r;
        this.building = false;
        this.loadInfo(); // refresh info
      },
      error: (err) => { this.error = err.error?.detail || err.message; this.building = false; },
    });
  }

  download() {
    window.open(this.api.getAgentPackageDownloadUrl(this.uc.activeKey), '_blank');
  }
}
