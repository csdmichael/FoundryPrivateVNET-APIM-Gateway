import { Component, OnInit, OnDestroy } from '@angular/core';
import { Subscription } from 'rxjs';
import { ApiService } from '../services/api.service';
import { UseCaseService } from '../services/use-case.service';

interface HistoryEntry {
  role: string;
  text: string;
  sources?: string[];
  duration_ms?: number;
  attempts?: number;
  timestamp: string;
  feedbackGiven?: string | null;
  query?: string;
}

interface FeedbackEntry {
  timestamp: string;
  query: string;
  document_id: string;
  relevant: boolean;
  search_score: number;
  notes: string;
}

@Component({
  selector: 'app-history',
  templateUrl: './history.page.html',
  styleUrls: ['./history.page.scss'],
  standalone: false,
})
export class HistoryPage implements OnInit, OnDestroy {
  activeTab = 'conversations';

  conversations: HistoryEntry[] = [];
  feedback: FeedbackEntry[] = [];
  private ucSub!: Subscription;

  constructor(public uc: UseCaseService, private api: ApiService) {}

  ngOnInit() {
    this.ucSub = this.uc.active$.subscribe(() => this.loadAll());
  }

  ngOnDestroy() { if (this.ucSub) this.ucSub.unsubscribe(); }

  loadAll() {
    this.loadConversations();
    this.loadFeedback();
  }

  loadConversations() {
    try {
      const saved = localStorage.getItem('chat_history');
      if (saved) {
        const parsed = JSON.parse(saved);
        this.conversations = (parsed[this.uc.activeKey] || []).filter(
          (m: HistoryEntry) => m.role === 'assistant'
        );
      } else {
        this.conversations = [];
      }
    } catch {
      this.conversations = [];
    }
  }

  loadFeedback() {
    this.api.getFeedback(this.uc.activeKey).subscribe({
      next: (data) => { this.feedback = data; },
      error: () => { this.feedback = []; },
    });
  }

  getFeedbackIcon(entry: HistoryEntry): string {
    if (entry.feedbackGiven === 'up') return 'thumbs-up';
    if (entry.feedbackGiven === 'down') return 'thumbs-down';
    return 'remove-outline';
  }

  getFeedbackColor(entry: HistoryEntry): string {
    if (entry.feedbackGiven === 'up') return 'success';
    if (entry.feedbackGiven === 'down') return 'danger';
    return 'medium';
  }

  clearHistory() {
    localStorage.removeItem('chat_history');
    this.conversations = [];
  }

  get positiveFeedbackCount(): number {
    return this.feedback.filter((f) => f.relevant).length;
  }

  get negativeFeedbackCount(): number {
    return this.feedback.filter((f) => !f.relevant).length;
  }
}
