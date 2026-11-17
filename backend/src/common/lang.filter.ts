import { ArgumentsHost, Catch, HttpException } from '@nestjs/common';
import { BaseExceptionFilter } from '@nestjs/core';
import type { Request } from 'express';
import { tr } from './i18n';

/**
 * Poruke grešaka na jeziku aplikacije: aplikacija za igrače šalje zaglavlje x-lang (en/sr).
 * Admin panel ga ne šalje i ostaje na srpskom.
 */
@Catch()
export class LangExceptionFilter extends BaseExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost) {
    const req = host.switchToHttp().getRequest<Request>();
    const lang = req?.headers?.['x-lang'];
    if (lang && exception instanceof HttpException) {
      const res = exception.getResponse();
      const translate = (m: unknown) => (typeof m === 'string' ? tr(m, String(lang)) : m);
      const body =
        typeof res === 'string'
          ? { statusCode: exception.getStatus(), message: translate(res) }
          : { ...(res as object), message: Array.isArray((res as { message?: unknown }).message) ? ((res as { message: unknown[] }).message).map(translate) : translate((res as { message?: unknown }).message ?? exception.message) };
      return super.catch(new HttpException(body, exception.getStatus()), host);
    }
    return super.catch(exception, host);
  }
}
