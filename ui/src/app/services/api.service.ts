import { Injectable } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { environment } from '../../environments/environment';

export interface ChatResponse {
  prompt: string;
  response: string;
  use_case: string;
  duration_ms: number;
  sources: string[];
  attempts: number;
}

export interface BatchResultItem {
  prompt: string;
  response: string;
  duration_ms: number;
  sources: string[];
  passed: boolean;
  reason: string;
}

export interface BatchResponse {
  use_case: string;
  total: number;
  passed: number;
  failed: number;
  accuracy_pct: number;
  results: BatchResultItem[];
}

export interface SamplePrompt {
  text: string;
  category: string;
}

export interface PromptsMap {
  keyword: SamplePrompt[];
  semantic: SamplePrompt[];
  agent: SamplePrompt[];
}

export interface FeedbackRequest {
  query: string;
  document_id: string;
  relevant: boolean;
  score: number;
  notes: string;
  use_case: string;
}

export interface DocumentEntry {
  filename: string;
  doc_id: string;
  type: string;
  size_kb: number;
  title?: string;
  status?: string;
  document_number?: string;
  state?: string;
  confidence?: string;
}

export interface DocumentListResponse {
  use_case: string;
  total: number;
  documents: DocumentEntry[];
}

export interface DocumentDetail {
  format: string;
  doc_id: string;
  content: any;
}

@Injectable({ providedIn: 'root' })
export class ApiService {
  private base = environment.apiUrl;

  constructor(private http: HttpClient) {}

  getPrompts(useCase: string): Observable<PromptsMap> {
    return this.http.get<PromptsMap>(`${this.base}/prompts`, { params: { use_case: useCase } });
  }

  chat(prompt: string, useCase: string): Observable<ChatResponse> {
    return this.http.post<ChatResponse>(`${this.base}/chat`, { prompt, use_case: useCase });
  }

  batchRun(prompts: string[], useCase: string): Observable<BatchResponse> {
    return this.http.post<BatchResponse>(`${this.base}/batch`, { prompts, use_case: useCase });
  }

  submitFeedback(req: FeedbackRequest): Observable<any> {
    return this.http.post(`${this.base}/feedback`, req);
  }

  getFeedback(useCase: string): Observable<any[]> {
    return this.http.get<any[]>(`${this.base}/feedback`, { params: { use_case: useCase } });
  }

  listDocuments(useCase: string): Observable<DocumentListResponse> {
    return this.http.get<DocumentListResponse>(`${this.base}/documents`, { params: { use_case: useCase } });
  }

  getDocument(docId: string, useCase: string): Observable<DocumentDetail> {
    return this.http.get<DocumentDetail>(`${this.base}/documents/${docId}`, { params: { use_case: useCase } });
  }

  getDocumentFileText(docId: string, useCase: string): Observable<string> {
    return this.http.get(`${this.base}/documents/${docId}/file`, {
      params: { use_case: useCase },
      responseType: 'text',
    });
  }

  getDocumentFileUrl(docId: string, useCase: string): string {
    return `${this.base}/documents/${docId}/file?use_case=${useCase}`;
  }

  getPdfUrl(docId: string, useCase: string): string {
    return this.getDocumentFileUrl(docId, useCase);
  }
}
