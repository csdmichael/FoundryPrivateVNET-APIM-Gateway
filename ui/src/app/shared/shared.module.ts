import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonicModule } from '@ionic/angular';
import { TestResultCardComponent } from './test-result-card.component';
import { KpiBadgeComponent } from './kpi-badge.component';

@NgModule({
  declarations: [TestResultCardComponent, KpiBadgeComponent],
  imports: [CommonModule, IonicModule],
  exports: [TestResultCardComponent, KpiBadgeComponent],
})
export class SharedModule {}
