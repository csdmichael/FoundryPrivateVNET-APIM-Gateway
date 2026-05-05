import { Component } from '@angular/core';
import { UseCaseService } from './services/use-case.service';

@Component({
  selector: 'app-root',
  templateUrl: 'app.component.html',
  styleUrls: ['app.component.scss'],
  standalone: false,
})
export class AppComponent {
  constructor(public ucService: UseCaseService) {}

  onUseCaseChange(key: string) {
    this.ucService.switch(key);
  }
}
