import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import { AgentPackagePage } from './agent-package.page';

const routes: Routes = [{ path: '', component: AgentPackagePage }];

@NgModule({
  imports: [RouterModule.forChild(routes)],
  exports: [RouterModule],
})
export class AgentPackageRoutingModule {}
