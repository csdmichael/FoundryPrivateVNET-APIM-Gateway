import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonicModule } from '@ionic/angular';
import { RouterModule } from '@angular/router';
import { DocumentsPage } from './documents.page';

@NgModule({
  imports: [
    CommonModule,
    FormsModule,
    IonicModule,
    RouterModule.forChild([
      { path: '', component: DocumentsPage },
      { path: ':docId', component: DocumentsPage },
    ]),
  ],
  declarations: [DocumentsPage],
})
export class DocumentsPageModule {}
