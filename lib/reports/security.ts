import "server-only";
import { createHmac, timingSafeEqual } from "node:crypto";

export const REPORT_TYPES=[
  "student_progress","programme_enrolments","course_performance","module_performance",
  "assessment_outcomes","certification_eligibility","certificates_issued","tutor_engagement",
  "content_approvals","feedback_ratings","completion_trends","marketplace_activity","platform_summary",
] as const;
export type ReportType=typeof REPORT_TYPES[number];
export type ReportFormat="csv"|"pdf";
export type ReportFilters={start_date?:string;end_date?:string;programme_id?:string;course_id?:string;module_id?:string;tutor_id?:string;student_id?:string;status?:string};
export type ReportToken={uid:string;exp:number;type:ReportType;format:ReportFormat;filters:ReportFilters};

function secret(){const key=process.env.REPORT_SIGNING_SECRET;if(!key||key.length<32)throw new Error("REPORT_SIGNING_SECRET must contain at least 32 characters.");return key;}
export function createReportToken(payload:Omit<ReportToken,"exp">,lifetimeSeconds=600){const body=Buffer.from(JSON.stringify({...payload,exp:Math.floor(Date.now()/1000)+lifetimeSeconds} satisfies ReportToken)).toString("base64url");const signature=createHmac("sha256",secret()).update(body).digest("base64url");return `${body}.${signature}`;}
export function readReportToken(token:string):ReportToken|null{try{const [body,provided,...rest]=token.split(".");if(!body||!provided||rest.length)return null;const expected=createHmac("sha256",secret()).update(body).digest();const supplied=Buffer.from(provided,"base64url");if(expected.length!==supplied.length||!timingSafeEqual(expected,supplied))return null;const value=JSON.parse(Buffer.from(body,"base64url").toString("utf8")) as ReportToken;if(!value.uid||value.exp<=Math.floor(Date.now()/1000)||!REPORT_TYPES.includes(value.type)||!(value.format==="csv"||value.format==="pdf"))return null;return value;}catch{return null;}}
