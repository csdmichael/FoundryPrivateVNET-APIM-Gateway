import { NgModule } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { IonicModule } from '@ionic/angular';
import { RouterModule } from '@angular/router';
import { ChatPage } from './chat.page';
import { FormatResponsePipe } from '../pipes/format-response.pipe';

@NgModule({
  imports: [
    CommonModule,
    FormsModule,
    IonicModule,
    RouterModule.forChild([{ path: '', component: ChatPage }]),
  ],
  declarations: [ChatPage, FormatResponsePipe],
})
export class ChatPageModule {}
