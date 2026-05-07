import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import { TestSearchPage } from './test-search.page';

const routes: Routes = [{ path: '', component: TestSearchPage }];

@NgModule({
  imports: [RouterModule.forChild(routes)],
  exports: [RouterModule],
})
export class TestSearchRoutingModule {}
