export async function closeManagedContext({
  context,
  outcome,
  disposeChild,
  cleanupWorkspace,
  closeState,
  assertClosable = async () => {},
}) {
  await assertClosable(context.id);
  if (context.childSessionId !== undefined) {
    await disposeChild(context.childSessionId, context.parentSessionId);
  }
  if (context.workspacePath !== undefined) {
    await cleanupWorkspace({
      path: context.workspacePath,
      worktreeRoot: context.worktreeRoot,
      branch: context.branch,
      gitRoot: context.gitRoot,
    });
  }
  await closeState(context.id, outcome);
}

export function shouldCloseContextOnAdoption(run) {
  return run.adapter === "dsh"
    && run.mode === "execution"
    && run.contextId !== undefined;
}

export function shouldCleanupAdoptedRun(run) {
  if (run.adapter === "dsh") {
    return shouldCloseContextOnAdoption(run) && run.adopted !== true;
  }
  return run.worktreePath !== undefined
    && !(run.workspaceCleaned === true && run.workspaceOutcome === "adopted");
}

export function shouldInspectWorkspaceBeforeCleanup(run, outcome) {
  return run.workspaceCleanupIntent?.outcome !== outcome;
}

export function shouldInspectContextBeforeClose(context, outcome) {
  return context.closeIntent?.outcome !== outcome;
}

export async function recoverPendingContextCloses(
  pending,
  closeContext,
  onError = () => {},
) {
  for (const item of pending) {
    try {
      await closeContext(item.contextId, item.outcome);
    } catch (error) {
      onError(item, error);
    }
  }
}

export async function runDurableIntegrationCompletion({
  batchId,
  rootSessionId,
  resume,
  markFailed,
  publish,
}) {
  try {
    return await resume(batchId);
  } catch (error) {
    await markFailed(batchId, error);
    await publish(rootSessionId);
    throw error;
  }
}
