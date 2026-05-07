import { Component } from '@angular/core';
import { UseCaseService } from '../services/use-case.service';
import { DeviceService } from '../services/device.service';

@Component({
  selector: 'app-home',
  templateUrl: 'home.page.html',
  styleUrls: ['home.page.scss'],
  standalone: false,
})
export class HomePage {
  steps = [
    { num: 1, icon: 'search-outline', title: 'AI Search Health', route: '/test-search', desc: 'Verify AI Search service is reachable, the index exists, and inspect document count and field schema.' },
    { num: 2, icon: 'flash-outline', title: 'Foundry Agent (Direct)', route: '/test-foundry', desc: 'Send a sample prompt directly to the Foundry Agent endpoint and verify the agent responds correctly.' },
    { num: 3, icon: 'cloud-outline', title: 'APIM Gateway', route: '/test-apim', desc: 'Route the same prompt through Azure API Management to confirm the gateway proxies to the Foundry Agent.' },
    { num: 4, icon: 'chatbubbles-outline', title: 'Bot Service', route: '/test-bot', desc: 'Send the prompt to the Bot Service API to validate the full Teams-compatible chat pipeline.' },
    { num: 5, icon: 'download-outline', title: 'Agent Package', route: '/agent-package', desc: 'Build, download, and import the agent package into the Teams Developer Portal.' },
  ];

  constructor(public ucService: UseCaseService, public device: DeviceService) {}
}
