export async function recoverRootSessions(roots, createSession, onError = () => {}) {
  for (const root of roots) {
    try {
      const response = await createSession({
        rpcId: `agent-platform-recover-${root.sessionId}`,
        payload: {
          sessionId: root.sessionId,
          cwd: root.cwd,
        },
      });
      if (response?.result?.ok !== true) {
        throw new Error(response?.result?.error?.message ?? "root session recovery was rejected");
      }
    } catch (error) {
      onError(root, error);
    }
  }
}
