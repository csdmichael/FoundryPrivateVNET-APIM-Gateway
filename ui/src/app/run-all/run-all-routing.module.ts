import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import { RunAllPage } from './run-all.page';

const routes: Routes = [{ path: '', component: RunAllPage }];

@NgModule({
  imports: [RouterModule.forChild(routes)],
  exports: [RouterModule],
})
export class RunAllRoutingModule {}
