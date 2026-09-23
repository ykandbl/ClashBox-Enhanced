import { Context, WantAgent, wantAgent } from "@kit.AbilityKit";
import { backgroundTaskManager } from "@kit.BackgroundTasksKit";
import { notificationManager } from "@kit.NotificationKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";

/**
 * VPN 长时保活任务。
 *
 * HarmonyOS 要求 dataTransfer 长时任务定期更新下载进度；超过 10 分钟不更新会被系统撤销。
 * 手机不开放普通应用的 taskKeeping，因此这里用系统支持的 dataTransfer 实况窗进度保活，
 * 并监听系统的挂起/撤销事件做自恢复。
 */
export class BackgroundDownService {
  private notificationId?: number = undefined;
  private continuousTaskId?: number = undefined;
  private noticeTimer?: number;
  private context?: Context;
  private expectedRunning: boolean = false;
  private taskSuspended: boolean = false;
  private recovering: boolean = false;
  private starting: boolean = false;
  private listenerRegistered: boolean = false;
  private recoveryTimer?: number;
  private lifecycleQueue: Promise<void> = Promise.resolve();
  private heartbeatProgress: number = 0;
  private nodeName: string = "代理节点";
  private uploadSpeed: string = "0 B";
  private downloadSpeed: string = "0 B";
  private showTraffic: boolean = true;
  private speedNoticeTimer?: number;
  private lastNoticePublishedAt: number = 0;
  private noticePublishing: boolean = false;

  /**
   * 返回最近一次由系统登记或 startBackgroundRunning 确认的状态。
   * ensureContinuousTask 每 30 秒会再次向系统复核，因此诊断页读取这里既不会
   * 阻塞 UI，也不会把页面上下文中的系统 RPC 卡顿误报成任务已丢失。
   */
  isContinuousTaskRunning(): boolean {
    return this.expectedRunning && this.notificationId !== undefined && !this.taskSuspended;
  }

  /**
   * 把实时节点/网速写入系统 dataTransfer 通知。这里只更新同一个系统分配的
   * notificationId，不再额外发布普通文本通知，因此通知栏始终只有一个 VPN 项。
   */
  updateTraffic(nodeName: string, upload: string, download: string, showTraffic: boolean = true): void {
    this.nodeName = nodeName.trim() || "代理节点";
    this.uploadSpeed = upload || "0 B";
    this.downloadSpeed = download || "0 B";
    this.showTraffic = showTraffic;
    if (!this.expectedRunning || this.notificationId === undefined) return;

    const elapsed = Date.now() - this.lastNoticePublishedAt;
    if (elapsed >= 1500 && !this.noticePublishing) {
      this.updateProgressNotification(false);
      return;
    }
    if (this.speedNoticeTimer !== undefined) return;
    this.speedNoticeTimer = setTimeout((): void => {
      this.speedNoticeTimer = undefined;
      this.updateProgressNotification(false);
    }, Math.max(100, 1500 - elapsed));
  }

  private readonly cancelCallback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    hilog.warn(0xFF00, "BackgroundDownService",
      `dataTransfer 长时任务被撤销 reason=${info.reason}, detailedReason=${JSON.stringify(info.detailedReason)}, id=${info.id}`);
    // ContinuousTaskCancelInfo.id is the continuous-task ID, not the
    // notification ID.  An old task can still emit its cancel callback after
    // a replacement task has been installed; never clear the replacement in
    // that case.
    if (this.continuousTaskId === undefined || this.continuousTaskId !== info.id) {
      hilog.info(0xFF00, "BackgroundDownService",
        `忽略非当前 dataTransfer 任务撤销回调 currentTaskId=${this.continuousTaskId}, callbackTaskId=${info.id}`);
      this.scheduleRecovery(1000);
      return;
    }
    this.notificationId = undefined;
    this.continuousTaskId = undefined;
    this.taskSuspended = false;
    if (this.expectedRunning) {
      this.scheduleRecovery(1000);
    }
  };

  private readonly suspendCallback = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
    if (this.continuousTaskId === undefined) {
      // The first lifecycle callback can arrive before the follow-up task
      // query has returned.  Adopt the ID so a subsequent cancel event still
      // belongs to the task that this service started.
      this.continuousTaskId = info.continuousTaskId;
    }
    if (this.continuousTaskId !== info.continuousTaskId) {
      hilog.info(0xFF00, "BackgroundDownService",
        `忽略非当前 dataTransfer 任务挂起回调 currentTaskId=${this.continuousTaskId}, callbackTaskId=${info.continuousTaskId}`);
      return;
    }
    this.taskSuspended = info.suspendState;
    hilog.warn(0xFF00, "BackgroundDownService",
      `dataTransfer 长时任务状态变化 suspended=${info.suspendState}, reason=${info.suspendReason}, id=${info.continuousTaskId}`);
  };

  private readonly activeCallback = (info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
    if (this.continuousTaskId !== undefined && this.continuousTaskId !== info.id) {
      hilog.info(0xFF00, "BackgroundDownService",
        `忽略非当前 dataTransfer 任务恢复回调 currentTaskId=${this.continuousTaskId}, callbackTaskId=${info.id}`);
      return;
    }
    this.continuousTaskId = info.id;
    this.taskSuspended = false;
    hilog.info(0xFF00, "BackgroundDownService", `dataTransfer 长时任务恢复活动 id=${info.id}`);
  };

  /**
   * 启动后台任务与通知
   */
  async start(context: Context): Promise<boolean> {
    // EntryAbility.onBackground and ClashViewModel.markVpnStarted can arrive
    // in either order.  Serialize the complete service lifecycle so a slow
    // system RPC cannot create two tasks or let a stop cancel a newer task.
    const operation: Promise<boolean> = this.lifecycleQueue.then((): Promise<boolean> =>
      this.startInternal(context));
    this.lifecycleQueue = operation.then((): void => {}, (): void => {});
    return await operation;
  }

  private async startInternal(context: Context): Promise<boolean> {
    this.context = context;
    this.expectedRunning = true;
    this.taskSuspended = false;
    this.registerLifecycleListeners();
    this.starting = true;
    try {
      // A UIAbility can be recreated while the system task survives.  Adopt
      // that task instead of requesting a second one.
      const existing = await this.findContinuousTask(context);
      if (existing) {
        this.adoptTask(existing);
        this.startNoticeTimer();
        if (!existing.suspendState) await this.updateProgressNotification();
        hilog.info(0xFF00, "BackgroundDownService",
          `复用已登记 dataTransfer 长时任务 taskId=${existing.continuousTaskId}, suspended=${existing.suspendState}`);
        return !existing.suspendState;
      }

      const id = await this.startContinuousTask(context);
      // startBackgroundRunning 可能在系统 RPC 中停留数秒。若期间 VPN 已停止，
      // 让排队中的 stop 操作完成清理，不把迟到结果接管成新的保活任务。
      if (!this.expectedRunning) return false;
      if (id < 0) {
        hilog.error(0xFF00, "BackgroundDownService", "无法启动后台长时任务");
        return false;
      }

      this.notificationId = id;
      this.continuousTaskId = undefined;
      this.taskSuspended = false;
      // Resolve the task ID immediately where the API exposes it.  The
      // notification API returns only notificationId on older API models.
      const startedTask = await this.findContinuousTask(context);
      if (startedTask) this.adoptTask(startedTask);
      this.startNoticeTimer();
      await this.updateProgressNotification();
      await this.cleanupLegacyTrafficNotifications();
      hilog.info(0xFF00, "BackgroundDownService",
        `dataTransfer 后台长时任务已启动 notificationId=${this.notificationId}, taskId=${this.continuousTaskId}`);
      return !this.taskSuspended;
    } finally {
      this.starting = false;
    }
  }

  /**
   * 停止后台任务
   */
  async stop(context: Context): Promise<void> {
    this.expectedRunning = false;
    this.cancelScheduledRecovery();
    const operation: Promise<void> = this.lifecycleQueue.then(async (): Promise<void> => {
      await this.stopInternal(context);
    });
    this.lifecycleQueue = operation.then((): void => {}, (): void => {});
    await operation;
  }

  private async stopInternal(context: Context): Promise<void> {
    this.expectedRunning = false;
    clearInterval(this.noticeTimer);
    this.noticeTimer = undefined;
    clearTimeout(this.speedNoticeTimer);
    this.speedNoticeTimer = undefined;

    this.notificationId = undefined;
    this.continuousTaskId = undefined;
    this.taskSuspended = false;
    this.context = undefined;
    this.unregisterLifecycleListeners();
    hilog.info(0xFF00, "BackgroundDownService", "准备停止后台任务");

    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      hilog.info(0xFF00, "BackgroundDownService", "后台任务停止成功");
    } catch (err) {
      hilog.error(
        0xFF00,
        "BackgroundDownService",
        `后台任务停止失败：${JSON.stringify(err)}`
      );
    }
  }

  /** 检查系统长时任务登记，被撤销时自动恢复。 */
  async ensureContinuousTask(): Promise<void> {
    if (!this.context || !this.expectedRunning || this.recovering || this.starting) return;
    try {
      const context = this.context;
      const task = await this.findContinuousTask(context);
      if (task) {
        this.adoptTask(task);
        hilog.info(0xFF00, "BackgroundDownService",
          `dataTransfer 长时任务状态 pid=${task.pid}, taskId=${task.continuousTaskId}, suspended=${task.suspendState}`);
        // A suspended task is a system state, not a missing task.  Recreating
        // it immediately causes duplicate requests and often turns a single
        // low-speed suspension into a full VPN teardown.
        if (task.suspendState) return;
        await this.updateProgressNotification();
        return;
      }
      hilog.warn(0xFF00, "BackgroundDownService", "未查到 dataTransfer 长时任务，准备自动恢复");
    } catch (err) {
      hilog.warn(0xFF00, "BackgroundDownService",
        `dataTransfer 长时任务查询异常，准备自动恢复: ${JSON.stringify(err)}`);
    }

    this.recovering = true;
    try {
      const context = this.context;
      if (!context || !this.expectedRunning) return;
      const id = await this.startContinuousTask(context);
      if (id >= 0 && this.expectedRunning) {
        this.notificationId = id;
        this.continuousTaskId = undefined;
        this.taskSuspended = false;
        const recoveredTask = await this.findContinuousTask(context);
        if (recoveredTask) this.adoptTask(recoveredTask);
        this.startNoticeTimer();
        await this.updateProgressNotification();
        hilog.info(0xFF00, "BackgroundDownService",
          `dataTransfer 长时任务已自动恢复 notificationId=${id}, taskId=${this.continuousTaskId}`);
      }
    } finally {
      this.recovering = false;
    }
  }

  private async findContinuousTask(context: Context): Promise<backgroundTaskManager.ContinuousTaskInfo | undefined> {
    const tasks = await backgroundTaskManager.getAllContinuousTasks(context, true);
    const bundleName = context.applicationInfo.name;
    return tasks.find((item: backgroundTaskManager.ContinuousTaskInfo): boolean =>
      item.abilityName === "EntryAbility" &&
      item.backgroundModes.includes("dataTransfer") &&
      (item.bundleName === undefined || item.bundleName === bundleName));
  }

  private adoptTask(task: backgroundTaskManager.ContinuousTaskInfo): void {
    this.notificationId = task.notificationId;
    this.continuousTaskId = task.continuousTaskId;
    this.taskSuspended = task.suspendState;
  }

  private startNoticeTimer(): void {
    clearInterval(this.noticeTimer);
    this.noticeTimer = setInterval(async (): Promise<void> => {
      await this.updateProgressNotification();
      await this.ensureContinuousTask();
    }, 30000);
  }

  private scheduleRecovery(delayMs: number): void {
    if (!this.expectedRunning || this.recoveryTimer !== undefined) return;
    this.recoveryTimer = setTimeout(async (): Promise<void> => {
      this.recoveryTimer = undefined;
      await this.ensureContinuousTask();
    }, delayMs);
  }

  private cancelScheduledRecovery(): void {
    if (this.recoveryTimer !== undefined) clearTimeout(this.recoveryTimer);
    this.recoveryTimer = undefined;
  }

  /**
   * 启动 HarmonyOS 后台长时任务
   */
  private async startContinuousTask(context: Context): Promise<number> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.applicationInfo.name,
          abilityName: "EntryAbility",
        },
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };

    try {
      const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      const result = await backgroundTaskManager.startBackgroundRunning(
        context,
        ["dataTransfer"],
        wantAgentObj
      );
      hilog.info(
        0xFF00,
        "BackgroundDownService",
        `长时任务启动成功 notificationId=${result.notificationId}`
      );
      return result.notificationId;
    } catch (err) {
      hilog.error(
        0xFF00,
        "BackgroundDownService",
        `长时任务启动失败: Code=${err.code}, Msg=${err.message}`
      );
      return -1;
    }
  }

  /**
   * 使用系统 dataTransfer 实况窗更新任务进度。
   * VPN 没有固定总量，进度在 1..99 之间循环；每次变化都代表隧道仍在处理数据。
   */
  private async updateProgressNotification(advanceHeartbeat: boolean = true): Promise<void> {
    if (this.notificationId === undefined || !this.expectedRunning || this.noticePublishing) return;
    this.noticePublishing = true;
    if (advanceHeartbeat) {
      this.heartbeatProgress = this.heartbeatProgress >= 99 ? 1 : this.heartbeatProgress + 1;
    }
    // 节点名可能很长；把它放到标题，把两项速度独占副标题，避免通知窄屏
    // 截断后只看得到上行、看不到下行。
    const statusTitle = `VPN 隧道运行中 · ${this.nodeName}`;
    const detail = this.showTraffic ?
      `↑ ${this.uploadSpeed}/s   ↓ ${this.downloadSpeed}/s` : "代理服务保持运行";
    const template: notificationManager.NotificationTemplate = {
      name: "downloadTemplate",
      data: {
        title: statusTitle,
        fileName: detail,
        progressValue: this.heartbeatProgress,
      },
    };
    const request: notificationManager.NotificationRequest = {
      id: this.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: template,
      content: {
        notificationContentType:
        notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: 8,
          title: statusTitle,
          text: detail,
        },
      },
    };
    try {
      await notificationManager.publish(request);
      this.lastNoticePublishedAt = Date.now();
      hilog.info(0xFF00, "BackgroundDownService",
        `dataTransfer 通知已更新 progress=${this.heartbeatProgress}, notificationId=${this.notificationId}`);
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(0xFF00, "BackgroundDownService",
        `dataTransfer 进度更新失败 Code=${error.code}, Msg=${error.message}`);
    } finally {
      this.noticePublishing = false;
    }
  }

  /**
   * 清理旧版本单独发布的“节点名 + 上下行速度”普通通知。
   *
   * 覆盖安装会保留通知中心里已经发布的普通通知，单纯删除旧发布代码并不会
   * 自动把它撤回。这里在新的 dataTransfer 通知落地后枚举本应用通知，只删除
   * 具有旧网速文本特征且 ID 不等于当前系统长时任务 ID 的项，保留订阅更新等
   * 其他业务通知。
   */
  private async cleanupLegacyTrafficNotifications(): Promise<void> {
    if (this.notificationId === undefined) return
    try {
      const activeNotifications = await notificationManager.getActiveNotifications()
      for (const request of activeNotifications) {
        const requestId = request.id
        const legacyText = request.content.normal?.text ?? ''
        const isLegacyTraffic = legacyText.includes('/s ↑') && legacyText.includes('/s ↓')
        if (requestId !== undefined && requestId !== this.notificationId && isLegacyTraffic) {
          await notificationManager.cancel(requestId)
          hilog.info(0xFF00, "BackgroundDownService",
            `已清理旧版独立网速通知 notificationId=${requestId}`)
        }
      }
    } catch (err) {
      hilog.warn(0xFF00, "BackgroundDownService",
        `旧版独立网速通知清理失败: ${JSON.stringify(err)}`)
    }
  }

  private registerLifecycleListeners(): void {
    if (this.listenerRegistered) return;
    try {
      backgroundTaskManager.on("continuousTaskCancel", this.cancelCallback);
      backgroundTaskManager.on("continuousTaskSuspend", this.suspendCallback);
      backgroundTaskManager.on("continuousTaskActive", this.activeCallback);
      this.listenerRegistered = true;
    } catch (err) {
      hilog.warn(0xFF00, "BackgroundDownService",
        `长时任务生命周期监听注册失败: ${JSON.stringify(err)}`);
    }
  }

  private unregisterLifecycleListeners(): void {
    if (!this.listenerRegistered) return;
    try {
      backgroundTaskManager.off("continuousTaskCancel", this.cancelCallback);
      backgroundTaskManager.off("continuousTaskSuspend", this.suspendCallback);
      backgroundTaskManager.off("continuousTaskActive", this.activeCallback);
    } catch (err) {
      hilog.warn(0xFF00, "BackgroundDownService",
        `长时任务生命周期监听注销失败: ${JSON.stringify(err)}`);
    }
    this.listenerRegistered = false;
  }
}

export default new BackgroundDownService();
