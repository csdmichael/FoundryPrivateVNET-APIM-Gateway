import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import { TestApimPage } from './test-apim.page';

const routes: Routes = [{ path: '', component: TestApimPage }];

@NgModule({
  imports: [RouterModule.forChild(routes)],
  exports: [RouterModule],
})
export class TestApimRoutingModule {}
