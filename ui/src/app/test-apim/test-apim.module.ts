import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonicModule } from '@ionic/angular';
import { SharedModule } from '../shared/shared.module';
import { TestApimPage } from './test-apim.page';
import { TestApimRoutingModule } from './test-apim-routing.module';

@NgModule({
  imports: [CommonModule, FormsModule, IonicModule, SharedModule, TestApimRoutingModule],
  declarations: [TestApimPage],
})
export class TestApimPageModule {}
