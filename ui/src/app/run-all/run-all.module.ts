import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonicModule } from '@ionic/angular';
import { SharedModule } from '../shared/shared.module';
import { RunAllPage } from './run-all.page';
import { RunAllRoutingModule } from './run-all-routing.module';

@NgModule({
  imports: [CommonModule, FormsModule, IonicModule, SharedModule, RunAllRoutingModule],
  declarations: [RunAllPage],
})
export class RunAllPageModule {}
