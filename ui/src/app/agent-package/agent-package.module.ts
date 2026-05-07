import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonicModule } from '@ionic/angular';
import { SharedModule } from '../shared/shared.module';
import { AgentPackagePage } from './agent-package.page';
import { AgentPackageRoutingModule } from './agent-package-routing.module';

@NgModule({
  imports: [CommonModule, IonicModule, SharedModule, AgentPackageRoutingModule],
  declarations: [AgentPackagePage],
})
export class AgentPackagePageModule {}
