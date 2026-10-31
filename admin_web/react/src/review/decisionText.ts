import type { ResolveRequest } from './source';

/** 「套用」「套用修改」「駁回」: one name per action, used by the button, the undo line and errors. */
export function actionVerb(request: ResolveRequest): string {
  if (request.decision === 'rejected') return '駁回';
  return request.edited ? '套用修改' : '套用';
}
