import { NgModule } from '@angular/core';
import { RouterModule, Routes } from '@angular/router';
import { TestBotPage } from './test-bot.page';

const routes: Routes = [{ path: '', component: TestBotPage }];

@NgModule({
  imports: [RouterModule.forChild(routes)],
  exports: [RouterModule],
})
export class TestBotRoutingModule {}
