import "server-only";
import PDFDocument from "pdfkit";
import type { ReportFormat, ReportToken } from "@/lib/reports/security";

export type ReportDocument={type:string;title:string;columns:string[];rows:unknown[][];filters:ReportToken["filters"];issued_at:string};
const printable=(value:unknown)=>String(value??"").replace(/\s+/g," ").normalize("NFKD").replace(/[^\x20-\x7E]/g," ").trim();
const csvCell=(value:unknown)=>{let text=String(value??"");if(/^[\s]*[=+@-]/.test(text))text=`'${text}`;return `"${text.replaceAll('"','""')}"`;};
export function renderCsv(report:ReportDocument){const filters=Object.entries(report.filters).filter(([,value])=>value).map(([key,value])=>[key.replaceAll("_"," "),value]);const lines=[[csvCell("GlowBiz report"),csvCell(report.title)],[csvCell("Issued at"),csvCell(new Date(report.issued_at).toISOString())],...filters.map(([key,value])=>[csvCell(key),csvCell(value)]),[],report.columns.map(csvCell),...report.rows.map(row=>report.columns.map((_,index)=>csvCell(row[index])))];return `\uFEFF${lines.map(row=>row.join(",")).join("\r\n")}`;}

export async function renderPdf(report:ReportDocument):Promise<Buffer>{
 const doc=new PDFDocument({size:"A4",layout:"landscape",margin:38,bufferPages:true,info:{Title:printable(report.title),Author:"GlowBiz",Subject:"Administrative report"}});
 const chunks:Buffer[]=[];const result=new Promise<Buffer>((resolve,reject)=>{doc.on("data",chunk=>chunks.push(Buffer.from(chunk)));doc.on("end",()=>resolve(Buffer.concat(chunks)));doc.on("error",reject);});
 const pageWidth=doc.page.width;const left=38;const usable=pageWidth-left*2;const bottom=doc.page.height-42;
 const title=printable(report.title);const issueDate=new Date(report.issued_at).toLocaleString("en-UG",{dateStyle:"medium",timeStyle:"short",timeZone:"Africa/Kampala"});
 const filters=Object.entries(report.filters).filter(([,value])=>value).map(([key,value])=>`${key.replaceAll("_"," ")}: ${value}`).join("  ·  ")||"No filters selected";
 const weights=report.columns.map(column=>Math.max(8,Math.min(26,column.length+4)));const totalWeight=weights.reduce((sum,value)=>sum+value,0);const widths=weights.map(weight=>usable*weight/totalWeight);
 let y=0;
 const drawBrand=()=>{doc.save().roundedRect(left,y,27,25,6).fill("#176b4d").restore();doc.fillColor("white").font("Helvetica-Bold").fontSize(10).text("GB",left,y+8,{width:27,align:"center"});doc.fillColor("#176b4d").font("Helvetica-Bold").fontSize(15).text("GlowBiz",left+36,y+1);doc.fillColor("#718078").font("Helvetica").fontSize(8).text("ADMINISTRATIVE REPORT",left+36,y+17);doc.fillColor("#718078").font("Helvetica").fontSize(8).text(`Issued ${issueDate}`,left,y+33);y+=52;doc.fillColor("#24352d").font("Helvetica-Bold").fontSize(17).text(title,left,y,{width:usable});y+=doc.heightOfString(title,{width:usable,fontSize:17})+5;doc.fillColor("#637169").font("Helvetica").fontSize(8).text(`Selected filters: ${printable(filters)}`,left,y,{width:usable});y+=doc.heightOfString(`Selected filters: ${printable(filters)}`,{width:usable,fontSize:8})+15;};
 const drawTableHeader=()=>{let x=left;doc.save().rect(left,y,usable,22).fill("#eaf3ed").restore();doc.font("Helvetica-Bold").fontSize(7).fillColor("#315340");report.columns.forEach((column,index)=>{doc.text(printable(column),x+4,y+7,{width:widths[index]-8,height:11,ellipsis:true});x+=widths[index];});y+=22;};
 const drawPageHeading=()=>{y=38;drawBrand();drawTableHeader();};
 drawPageHeading();
 for(const row of report.rows){const cells=report.columns.map((_,index)=>printable(row[index]));const heights=cells.map((cell,index)=>doc.heightOfString(cell||"—",{width:Math.max(20,widths[index]-8),font:"Helvetica",fontSize:7,lineGap:1}));const rowHeight=Math.max(22,...heights)+8;if(y+rowHeight>bottom){doc.addPage();drawPageHeading();}if(Math.floor(y/22)%2===0)doc.save().rect(left,y,usable,rowHeight).fill("#fbfcfb").restore();let x=left;doc.font("Helvetica").fontSize(7).fillColor("#36473e");cells.forEach((cell,index)=>{doc.text(cell||"—",x+4,y+5,{width:widths[index]-8,height:rowHeight-6,lineGap:1,ellipsis:true});x+=widths[index];});y+=rowHeight;}
 const range=doc.bufferedPageRange();for(let page=0;page<range.count;page++){doc.switchToPage(range.start+page);doc.moveTo(left,doc.page.height-32).lineTo(pageWidth-left,doc.page.height-32).strokeColor("#dce5de").stroke();doc.fillColor("#718078").font("Helvetica").fontSize(8).text("GlowBiz · Confidential administrative report",left,doc.page.height-24,{width:usable/2});doc.text(`Page ${page+1} of ${range.count}`,left+usable/2,doc.page.height-24,{width:usable/2,align:"right"});}
 doc.end();return result;
}
export function reportContentType(format:ReportFormat){return format==="pdf"?"application/pdf":"text/csv; charset=utf-8";}
