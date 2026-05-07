import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonicModule } from '@ionic/angular';
import { SharedModule } from '../shared/shared.module';
import { TestFoundryPage } from './test-foundry.page';
import { TestFoundryRoutingModule } from './test-foundry-routing.module';

@NgModule({
  imports: [CommonModule, FormsModule, IonicModule, SharedModule, TestFoundryRoutingModule],
  declarations: [TestFoundryPage],
})
export class TestFoundryPageModule {}
