import { Component, OnInit, OnDestroy } from '@angular/core';
import { Router } from '@angular/router';
import { ToastController } from '@ionic/angular';
import { Subscription } from 'rxjs';
import { ApiService, SamplePrompt, BatchResponse, BatchResultItem } from '../services/api.service';
import { UseCaseService } from '../services/use-case.service';

interface SelectablePrompt extends SamplePrompt {
  selected: boolean;
}

@Component({
  selector: 'app-prompts',
  templateUrl: './prompts.page.html',
  styleUrls: ['./prompts.page.scss'],
  standalone: false,
})
export class PromptsPage implements OnInit, OnDestroy {
  categories = ['keyword', 'semantic', 'agent'];
  prompts: Record<string, SelectablePrompt[]> = { keyword: [], semantic: [], agent: [] };

  isRunning = false;
  batchResult: BatchResponse | null = null;
  runProgress = 0;
  runTotal = 0;
  private ucSub!: Subscription;

  constructor(
    public uc: UseCaseService,
    private api: ApiService,
    private toast: ToastController,
    private router: Router,
  ) {}

  ngOnInit() {
    this.ucSub = this.uc.active$.subscribe(() => {
      this.batchResult = null;
      this.loadPrompts();
    });
  }

  ngOnDestroy() { if (this.ucSub) this.ucSub.unsubscribe(); }

  loadPrompts() {
    this.api.getPrompts(this.uc.activeKey).subscribe((data) => {
      for (const cat of this.categories) {
        const items = (data as any)[cat] || [];
        this.prompts[cat] = items.map((p: SamplePrompt) => ({ ...p, selected: false }));
      }
    });
  }

  get selectedCount(): number {
    const all: SelectablePrompt[] = ([] as SelectablePrompt[]).concat(...Object.values(this.prompts));
    return all.filter((p) => p.selected).length;
  }

  get allSelected(): boolean {
    const all: SelectablePrompt[] = ([] as SelectablePrompt[]).concat(...Object.values(this.prompts));
    return all.length > 0 && all.every((p) => p.selected);
  }

  toggleAll(checked: boolean) {
    for (const cat of this.categories) {
      this.prompts[cat].forEach((p) => (p.selected = checked));
    }
  }

  selectCategory(cat: string, checked: boolean) {
    this.prompts[cat].forEach((p) => (p.selected = checked));
  }

  isCategorySelected(cat: string): boolean {
    const items = this.prompts[cat];
    return items.length > 0 && items.every((p) => p.selected);
  }

  async copyPrompt(text: string) {
    await navigator.clipboard.writeText(text);
    const t = await this.toast.create({ message: 'Copied!', duration: 1200, position: 'bottom', color: 'success' });
    t.present();
  }

  useInChat(text: string) {
    this.router.navigate(['/chat'], { queryParams: { prompt: text, use_case: this.uc.activeKey } });
  }

  runSelected() {
    const selected: SelectablePrompt[] = ([] as SelectablePrompt[]).concat(...Object.values(this.prompts)).filter((p) => p.selected);
    if (selected.length === 0) return;

    this.isRunning = true;
    this.batchResult = null;
    this.runTotal = selected.length;
    this.runProgress = 0;

    const texts = selected.map((p) => p.text);

    this.api.batchRun(texts, this.uc.activeKey).subscribe({
      next: (res: BatchResponse) => {
        this.batchResult = res;
        this.runProgress = res.total;
        this.isRunning = false;
      },
      error: () => {
        this.isRunning = false;
      },
    });
  }

  getResultColor(item: BatchResultItem): string {
    return item.passed ? 'success' : 'danger';
  }

  getAccuracyColor(pct: number): string {
    if (pct >= 90) return 'success';
    if (pct >= 70) return 'warning';
    return 'danger';
  }

  openCitation(docId: string) {
    const encodedDocId = encodeURIComponent(docId);
    const encodedUseCase = encodeURIComponent(this.uc.activeKey);
    window.open(`/documents/${encodedDocId}?use_case=${encodedUseCase}`, '_blank', 'noopener,noreferrer');
  }
}
