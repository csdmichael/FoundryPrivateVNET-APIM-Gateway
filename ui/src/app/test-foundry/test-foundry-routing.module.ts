import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import { TestFoundryPage } from './test-foundry.page';

const routes: Routes = [{ path: '', component: TestFoundryPage }];

@NgModule({
  imports: [RouterModule.forChild(routes)],
  exports: [RouterModule],
})
export class TestFoundryRoutingModule {}
