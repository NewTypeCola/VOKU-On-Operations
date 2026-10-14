export type Totals = Record<
  | "events"
  | "browsers"
  | "sessions"
  | "returningBrowsers"
  | "pageViews"
  | "activeMs"
  | "reads"
  | "readOpens"
  | "qualifiedReads"
  | "completeReads"
  | "readMs"
  | "readPages"
  | "readToCompose"
  | "readToCommunity"
  | "qualifiedSessions"
  | "posts"
  | "comments"
  | "errors"
  | "shortVisits",
  number
>;
export type Row = Record<string, string | number | null>;
export type UsageReport = {
  definition: string;
  generatedAt: string;
  from: string;
  to: string;
  audience: string;
  timezone: string;
  totals: Totals;
  archive: Row[];
  sources: Row[];
  devices: Row[];
  routes: Row[];
  transitions: Row[];
  features: Row[];
  errors: Row[];
  performance: Row[];
  excluded: { staff: number; test: number; bot: number; sample: number };
  daily: { day: string; totals: Totals }[];
  coverage: {
    startedAt: string;
    lastReceivedAt: string | null;
    maintenanceAt: string | null;
    rawRetentionDays: number;
    visitorRetentionDays: number;
    aggregateRetentionYears: number;
    accepted: number;
    rejected: number;
    duplicates: number;
    clientDropped: number;
    storageBytes: number;
  };
  legacy: {
    notice: string;
    posts: number;
    comments: number;
    samplePosts: number;
    staffPosts: number;
    cumulativePostViews: number;
    archiveBookmarks: number;
  };
};
export type UsageTrend = {
  definition: string;
  from: string;
  to: string;
  audience: string;
  timezone: string;
  notice: string;
  days: { day: string; calculatedAt: string; data: UsageReport }[];
};
export type Snapshot = {
  id: string;
  createdAt: string;
  sha256: string;
  canonicalPayload: string;
};
