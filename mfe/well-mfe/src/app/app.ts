import { Component, OnInit, inject, signal } from '@angular/core';
import { HttpErrorResponse } from '@angular/common/http';
import { Api } from './api/api';
import { listWells } from './api/fn/wells/list-wells';
import { Well } from './api/models/well';
import { WellStatus } from './api/models/well-status';

/**
 * The MFE's single page: lists wells from well-registry (GET /v2/wells) through the client
 * GENERATED from the contract. `?status=` in the page URL is passed through as the filter.
 */
@Component({
  selector: 'app-root',
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App implements OnInit {
  private readonly api = inject(Api);

  protected readonly status = new URLSearchParams(window.location.search).get('status');
  protected readonly wells = signal<Well[] | null>(null);
  protected readonly error = signal<string | null>(null);

  async ngOnInit(): Promise<void> {
    try {
      // The URL is untyped user input: the cast compiles, but the CONTRACT (enforced by the
      // Specmatic stub or the real service) still decides whether the value is valid.
      const params = this.status ? { status: this.status as WellStatus } : {};
      this.wells.set(await this.api.invoke(listWells, params));
    } catch (e) {
      const err = e as HttpErrorResponse;
      this.error.set(`Request failed: HTTP ${err.status}`);
    }
  }

  /** Daily capacity in bbl/d, formatted for display (uses the typed contract field). */
  protected capacity(well: Well): string {
    return `${well.dailyCapacityBbl.toLocaleString('en-US')} bbl/d`;
  }
}
