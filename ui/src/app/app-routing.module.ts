import { NgModule } from '@angular/core';
import { PreloadAllModules, RouterModule, Routes } from '@angular/router';

const routes: Routes = [
  {
    path: 'home',
    loadChildren: () => import('./home/home.module').then(m => m.HomePageModule),
  },
  {
    path: 'run-all',
    loadChildren: () => import('./run-all/run-all.module').then(m => m.RunAllPageModule),
  },
  {
    path: 'test-search',
    loadChildren: () => import('./test-search/test-search.module').then(m => m.TestSearchPageModule),
  },
  {
    path: 'test-foundry',
    loadChildren: () => import('./test-foundry/test-foundry.module').then(m => m.TestFoundryPageModule),
  },
  {
    path: 'test-apim',
    loadChildren: () => import('./test-apim/test-apim.module').then(m => m.TestApimPageModule),
  },
  {
    path: 'test-bot',
    loadChildren: () => import('./test-bot/test-bot.module').then(m => m.TestBotPageModule),
  },
  {
    path: 'agent-package',
    loadChildren: () => import('./agent-package/agent-package.module').then(m => m.AgentPackagePageModule),
  },
  {
    path: 'chat',
    loadChildren: () => import('./chat/chat.module').then(m => m.ChatPageModule),
  },
  {
    path: 'prompts',
    loadChildren: () => import('./prompts/prompts.module').then(m => m.PromptsPageModule),
  },
  {
    path: 'documents',
    loadChildren: () => import('./documents/documents.module').then(m => m.DocumentsPageModule),
  },
  {
    path: '',
    redirectTo: 'home',
    pathMatch: 'full',
  },
];

@NgModule({
  imports: [
    RouterModule.forRoot(routes, { preloadingStrategy: PreloadAllModules })
  ],
  exports: [RouterModule]
})
export class AppRoutingModule { }
