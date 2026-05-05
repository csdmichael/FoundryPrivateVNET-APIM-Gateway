import { Pipe, PipeTransform } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';

function isCorpusCitationSource(source: string): boolean {
  const trimmed = source.trim();
  if (!trimmed) {
    return false;
  }
  if (/^https?:/i.test(trimmed)) {
    return false;
  }
  if (/[\\/]/.test(trimmed) || /[:?#]/.test(trimmed)) {
    return false;
  }
  return /(?:\.(txt|json|pdf|pptx?)|(MFG|FD)-TC-\d{4})$/i.test(trimmed);
}

@Pipe({ name: 'formatResponse', standalone: false })
export class FormatResponsePipe implements PipeTransform {
  constructor(private sanitizer: DomSanitizer) {}

  transform(text: string, useCase?: string): SafeHtml {
    if (!text) return '';

    let html = text
      // Escape HTML
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      // Bold **text**
      .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
      // Citations [source†index] — make clickable links to document viewer
      .replace(
        /\[([^\[\]†]+?)†([^\[\]]+?)\]/g,
        (_match: string, source: string, _index: string) => {
          if (!isCorpusCitationSource(source)) {
            return source;
          }
          const encodedSource = encodeURIComponent(source.trim());
          const encodedUseCase = encodeURIComponent(useCase || '');
          return `<a class="citation" href="/documents/${encodedSource}?use_case=${encodedUseCase}" data-doc-id="${encodedSource}" title="Open this source document">${source}</a>`;
        },
      )
      // Line breaks
      .replace(/\n/g, '<br>');

    return this.sanitizer.bypassSecurityTrustHtml(html);
  }
}
