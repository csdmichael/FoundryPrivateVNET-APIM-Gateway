import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonicModule } from '@ionic/angular';
import { SharedModule } from '../shared/shared.module';
import { TestBotPage } from './test-bot.page';
import { TestBotRoutingModule } from './test-bot-routing.module';

@NgModule({
  imports: [CommonModule, FormsModule, IonicModule, SharedModule, TestBotRoutingModule],
  declarations: [TestBotPage],
})
export class TestBotPageModule {}
