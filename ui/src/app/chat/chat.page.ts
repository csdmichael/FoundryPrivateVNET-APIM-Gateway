import { Component, ViewChild, ElementRef, OnInit, OnDestroy } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { Router } from '@angular/router';
import { Subscription } from 'rxjs';
import { ApiService, ChatResponse } from '../services/api.service';
import { UseCaseService } from '../services/use-case.service';

interface ChatMessage {
  role: 'user' | 'assistant';
  text: string;
  sources?: string[];
  duration_ms?: number;
  attempts?: number;
  timestamp: Date;
  feedbackGiven?: 'up' | 'down' | null;
  query?: string;
}

@Component({
  selector: 'app-chat',
  templateUrl: './chat.page.html',
  styleUrls: ['./chat.page.scss'],
  standalone: false,
})
export class ChatPage implements OnInit, OnDestroy {
  @ViewChild('chatContent', { read: ElementRef }) chatContent!: ElementRef;

  conversations: Record<string, ChatMessage[]> = {
    tax_pdf_forms: [],
    eng_design_ppt: [],
  };

  inputText = '';
  isLoading = false;
  feedbackNotes = '';
  private ucSub!: Subscription;

  constructor(
    public uc: UseCaseService,
    private api: ApiService,
    private route: ActivatedRoute,
    private router: Router,
  ) {}

  ngOnInit() {
    this.loadHistory();
    this.route.queryParams.subscribe((params) => {
      if (params['use_case']) {
        this.uc.switch(params['use_case']);
      }
      if (params['prompt']) {
        this.inputText = params['prompt'];
      }
    });
  }

  ngOnDestroy() {
    if (this.ucSub) this.ucSub.unsubscribe();
  }

  get activeUseCase(): string { return this.uc.activeKey; }

  get messages(): ChatMessage[] {
    return this.conversations[this.activeUseCase];
  }

  sendMessage() {
    const text = this.inputText.trim();
    if (!text || this.isLoading) return;

    this.messages.push({ role: 'user', text, timestamp: new Date() });
    this.inputText = '';
    this.isLoading = true;
    this.scrollToBottom();

    this.api.chat(text, this.activeUseCase).subscribe({
      next: (res: ChatResponse) => {
        this.messages.push({
          role: 'assistant',
          text: res.response,
          sources: res.sources,
          duration_ms: res.duration_ms,
          attempts: res.attempts,
          timestamp: new Date(),
          feedbackGiven: null,
          query: text,
        });
        this.isLoading = false;
        this.saveHistory();
        this.scrollToBottom();
      },
      error: (err) => {
        this.messages.push({
          role: 'assistant',
          text: 'Error: ' + (err.error?.detail || err.message || 'Request failed'),
          timestamp: new Date(),
        });
        this.isLoading = false;
        this.scrollToBottom();
      },
    });
  }

  onKeyDown(event: KeyboardEvent) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      this.sendMessage();
    }
  }

  onMessageContentClick(event: MouseEvent) {
    const target = event.target as HTMLElement | null;
    const citationLink = target?.closest('a.citation') as HTMLAnchorElement | null;
    const docId = citationLink?.dataset['docId'];
    if (!docId) {
      return;
    }

    event.preventDefault();
    this.router.navigate(['/documents', decodeURIComponent(docId)], {
      queryParams: { use_case: this.activeUseCase },
    });
  }

  giveFeedback(msg: ChatMessage, relevant: boolean) {
    msg.feedbackGiven = relevant ? 'up' : 'down';
    const sources = msg.sources || [];
    for (const docId of sources) {
      this.api.submitFeedback({
        query: msg.query || '',
        document_id: docId,
        relevant,
        score: 0,
        notes: this.feedbackNotes,
        use_case: this.activeUseCase,
      }).subscribe();
    }
  }

  clearChat() {
    this.conversations[this.activeUseCase] = [];
    this.saveHistory();
  }

  private saveHistory() {
    try {
      localStorage.setItem('chat_history', JSON.stringify(this.conversations));
    } catch { /* quota exceeded — ignore */ }
  }

  private loadHistory() {
    try {
      const saved = localStorage.getItem('chat_history');
      if (saved) {
        const parsed = JSON.parse(saved);
        for (const key of Object.keys(parsed)) {
          if (!(key in this.conversations)) {
            this.conversations[key] = [];
          }
          this.conversations[key] = parsed[key].map((m: any) => ({
            ...m,
            timestamp: new Date(m.timestamp),
          }));
        }
      }
    } catch { /* corrupted — ignore */ }
  }

  private scrollToBottom() {
    setTimeout(() => {
      if (this.chatContent?.nativeElement) {
        this.chatContent.nativeElement.scrollTop = this.chatContent.nativeElement.scrollHeight;
      }
    }, 100);
  }
}
