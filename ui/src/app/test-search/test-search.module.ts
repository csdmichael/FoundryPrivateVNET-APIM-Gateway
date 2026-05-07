import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { IonicModule } from '@ionic/angular';
import { SharedModule } from '../shared/shared.module';
import { TestSearchPage } from './test-search.page';
import { TestSearchRoutingModule } from './test-search-routing.module';

@NgModule({
  imports: [CommonModule, IonicModule, SharedModule, TestSearchRoutingModule],
  declarations: [TestSearchPage],
})
export class TestSearchPageModule {}
