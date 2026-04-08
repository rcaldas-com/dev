// Seed script for finance data - dumped from production DB 2026-04-08
// Run from project root:
//   cd ~/car && docker compose exec -T mongo mongosh --quiet -u user -p password --authenticationDatabase admin rcaldas < /home/robca/rcaldas/scripts/seed-finance.js

const userId = '5d40956a7533d51bf3839370';

// ==================== Clear existing data ====================
print('Clearing existing finance data...');
db.financeProfile.deleteMany({ userId });
db.financeCard.deleteMany({ userId });
db.financeExpense.deleteMany({ userId });
db.financeInstallment.deleteMany({ userId });
db.financeMonth.deleteMany({ userId });

// ==================== Profile ====================
print('Inserting profile...');
db.financeProfile.insertOne({
  userId,
  salary: { payment: 8841.12, advance: 8378.08, paymentDay: 7, advanceDay: 15 },
  foodVoucher: 2300,
  banks: [
    { name: 'MP', balance: 3740 },
    { name: 'BB', balance: 0 },
    { name: 'ITAU', balance: 0 },
  ],
  createdAt: new Date('2026-04-07T22:06:52.434Z'),
  updatedAt: new Date('2026-04-08T17:48:45.253Z'),
});

// ==================== Cards ====================
print('Inserting cards...');
const bbId   = db.financeCard.insertOne({ userId, name: 'BB',     dueDay: 10, invoiceTotal: 4360.09 }).insertedId;
const itauId = db.financeCard.insertOne({ userId, name: 'ITAU',   dueDay: 7,  invoiceTotal: 9886.28 }).insertedId;
const renId  = db.financeCard.insertOne({ userId, name: 'Renner', dueDay: 15, invoiceTotal: 198.36 }).insertedId;
const mpId   = db.financeCard.insertOne({ userId, name: 'MP',     dueDay: 1,  invoiceTotal: 151.43 }).insertedId;
const nbId   = db.financeCard.insertOne({ userId, name: 'NB',     dueDay: 5,  invoiceTotal: 0 }).insertedId;

// ==================== Expenses ====================
print('Inserting expenses...');
const expenses = [
  { name: 'Linode',        value: 145,    category: 'card', proportional: false,    dueDay: 1,    order: 0 },
  { name: 'Github',        value: 220,    category: 'card', proportional: false,    dueDay: 1,    order: 1 },
  { name: 'Telegram',      value: 32,     category: 'card', proportional: false,    dueDay: 13,   order: 2 },
  { name: 'Smiles',        value: 46,     category: 'card', proportional: false,    dueDay: 15,   order: 3 },
  { name: 'Cabelo',        value: 60,     category: 'card', proportional: false,    dueDay: null,  order: 4 },
  { name: 'Crédito Cel.',  value: 98,     category: 'card', proportional: false,    dueDay: 15,   order: 5 },
  { name: 'Internet',      value: 150,    category: 'card', proportional: false,    dueDay: 5,    order: 6 },
  { name: 'Uber',          value: 120,    category: 'card', proportional: 'weekly', dueDay: null,  order: 7 },
  { name: 'Roupa',         value: 60,     category: 'card', proportional: 'weekly', dueDay: null,  order: 8 },
  { name: 'Farmácia',      value: 100,    category: 'card', proportional: false,    dueDay: null,  order: 9 },
  { name: 'Compras',       value: 300,    category: 'card', proportional: false,    dueDay: null,  order: 10 },
  { name: 'Ensure',        value: 300,    category: 'card', proportional: false,    dueDay: null,  order: 11 },
  { name: 'Água',          value: 220,    category: 'cash', proportional: false,    dueDay: 10,   order: 12 },
  { name: 'Luz',           value: 207.82, category: 'cash', proportional: false,    dueDay: 10,   order: 13 },
  { name: 'Gás',           value: 150,    category: 'cash', proportional: false,    dueDay: null,  order: 14 },
  { name: 'Previdência',   value: 924.48, category: 'cash', proportional: false,    dueDay: 7,    order: 15 },
  { name: 'Pl. Saúde',     value: 512.81, category: 'cash', proportional: false,    dueDay: 7,    order: 16 },
  { name: 'Alim. Café',    value: 25,     category: 'cash', proportional: 'daily',  dueDay: null,  order: 17 },
  { name: 'Alim. Alm.',    value: 50,     category: 'cash', proportional: 'daily',  dueDay: null,  order: 18 },
  { name: 'Alim. Jant',    value: 40,     category: 'cash', proportional: 'daily',  dueDay: null,  order: 19 },
  { name: 'Transporte',    value: 16,     category: 'cash', proportional: 'daily',  dueDay: null,  order: 20 },
  { name: 'Aluguel',       value: 4181,   category: 'cash', proportional: false,    dueDay: 7,    order: 21 },
  { name: 'Paty Omega',    value: 1000,   category: 'cash', proportional: false,    dueDay: 7,    order: 22 },
];
const expIds = [];
expenses.forEach(e => {
  const r = db.financeExpense.insertOne({ ...e, userId });
  expIds.push(r.insertedId);
});

// ==================== Installments ====================
print('Inserting installments...');
const installments = [
  // BB
  { cardId: bbId, description: 'Reg Volt Omega Zamer',         monthlyValue: 106,    remainingInstallments: 2 },
  { cardId: bbId, description: 'Leroy Estante Ventilador',     monthlyValue: 299.65, remainingInstallments: 2 },
  { cardId: bbId, description: 'Leroy Fio 10mm',               monthlyValue: 209.15, remainingInstallments: 3 },
  { cardId: bbId, description: 'Comb Volta Cuiabá',            monthlyValue: 82.40,  remainingInstallments: 1 },
  { cardId: bbId, description: 'Comb 16/02 09h',               monthlyValue: 160.15, remainingInstallments: 1 },
  { cardId: bbId, description: 'Comando 13/03',                monthlyValue: 163.33, remainingInstallments: 3 },
  { cardId: bbId, description: 'Oceanfarma',                   monthlyValue: 62.63,  remainingInstallments: 2 },
  // ITAU
  { cardId: itauId, description: 'Geladeira Samsung',            monthlyValue: 204.60, remainingInstallments: 8 },
  { cardId: itauId, description: 'Cama Emma',                    monthlyValue: 483.24, remainingInstallments: 3 },
  { cardId: itauId, description: 'ML Casa',                      monthlyValue: 57.32,  remainingInstallments: 3 },
  { cardId: itauId, description: 'ML Casa',                      monthlyValue: 54.39,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Fogão',                        monthlyValue: 84.87,  remainingInstallments: 8 },
  { cardId: itauId, description: 'Guarda Roupa',                 monthlyValue: 196.59, remainingInstallments: 3 },
  { cardId: itauId, description: 'Mesa Jantar',                  monthlyValue: 139.41, remainingInstallments: 3 },
  { cardId: itauId, description: 'ML Casa',                      monthlyValue: 60.34,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Ml Casa',                      monthlyValue: 40.46,  remainingInstallments: 3 },
  { cardId: itauId, description: 'ML Banheiro Tomada',           monthlyValue: 73.15,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Escada',                       monthlyValue: 32.11,  remainingInstallments: 2 },
  { cardId: itauId, description: 'Ali Oring Escova Aço',         monthlyValue: 48.40,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Pneu Omega',                   monthlyValue: 137.74, remainingInstallments: 3 },
  { cardId: itauId, description: 'Aluguel Outubro',              monthlyValue: 653.05, remainingInstallments: 3 },
  { cardId: itauId, description: 'Bicos Verde Omega',            monthlyValue: 74.43,  remainingInstallments: 3 },
  { cardId: itauId, description: 'BMW 540i',                     monthlyValue: 1111.13, remainingInstallments: 14 },
  { cardId: itauId, description: 'Transf BMW',                   monthlyValue: 53.59,  remainingInstallments: 1 },
  { cardId: itauId, description: 'Micro Retifica',               monthlyValue: 53,     remainingInstallments: 3 },
  { cardId: itauId, description: 'Terminal Direção Omega',       monthlyValue: 52.76,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Sonda e Filtro Omega',         monthlyValue: 53.76,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Peças BMW',                    monthlyValue: 236.87, remainingInstallments: 8 },
  { cardId: itauId, description: 'ML BMW Bucha Paleta',          monthlyValue: 45.21,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Reserv Água BMW',              monthlyValue: 49.60,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Bieleta Malas BMW',            monthlyValue: 56.20,  remainingInstallments: 2 },
  { cardId: itauId, description: 'Lanterna e Bateria',           monthlyValue: 28.49,  remainingInstallments: 2 },
  { cardId: itauId, description: 'Pilhas Carregador',            monthlyValue: 107.44, remainingInstallments: 3 },
  { cardId: itauId, description: 'BMW Mala e Peças Limpador',    monthlyValue: 54.49,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Tripe Camera',                 monthlyValue: 34.75,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Bateria e Aste Limpador BM',   monthlyValue: 55.36,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Sopra Coxim Teclado',          monthlyValue: 191.94, remainingInstallments: 8 },
  { cardId: itauId, description: 'Solda Amazon',                 monthlyValue: 434.09, remainingInstallments: 8 },
  { cardId: itauId, description: 'BM Susp Tras',                 monthlyValue: 161.63, remainingInstallments: 8 },
  { cardId: itauId, description: 'Porca Eixo Tras Amaz',         monthlyValue: 36,     remainingInstallments: 3 },
  { cardId: itauId, description: 'Passagem CGB Abril',           monthlyValue: 246.45, remainingInstallments: 3 },
  { cardId: itauId, description: 'Prensa 15t',                   monthlyValue: 117.09, remainingInstallments: 8 },
  { cardId: itauId, description: 'Mascara Solda',                monthlyValue: 59.83,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Mancal e carregador pai',      monthlyValue: 39.58,  remainingInstallments: 2 },
  { cardId: itauId, description: 'Leroy Caixa Ferramentas',      monthlyValue: 209.03, remainingInstallments: 3 },
  { cardId: itauId, description: 'Motor Limpador BMW',           monthlyValue: 58.71,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Óculos Cuiabá',                monthlyValue: 117.51, remainingInstallments: 3 },
  { cardId: itauId, description: 'Pneu BMW Sia',                 monthlyValue: 270,    remainingInstallments: 3 },
  { cardId: itauId, description: 'Galão Oleo 10w40',             monthlyValue: 213.34, remainingInstallments: 2 },
  { cardId: itauId, description: 'Passagem Rio ult hora',        monthlyValue: 413.66, remainingInstallments: 3 },
  { cardId: itauId, description: 'Reservatorio e Display BMW',   monthlyValue: 75.92,  remainingInstallments: 10 },
  { cardId: itauId, description: 'Bucha Elastica BMW',           monthlyValue: 52.90,  remainingInstallments: 8 },
  { cardId: itauId, description: 'Tirante e Coxins BMW - ML',    monthlyValue: 91.80,  remainingInstallments: 10 },
  { cardId: itauId, description: 'Tirante e Coxins BMW - Amz',   monthlyValue: 50.20,  remainingInstallments: 8 },
  { cardId: itauId, description: 'Sensor Flex',                  monthlyValue: 48.14,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Corrida RJ Maio',              monthlyValue: 45.84,  remainingInstallments: 3 },
  { cardId: itauId, description: 'Cacaushow Pascoa',             monthlyValue: 127.65, remainingInstallments: 3 },
  { cardId: itauId, description: 'Escapamento Omega Ref',        monthlyValue: 100,    remainingInstallments: 3 },
  { cardId: itauId, description: 'Combst Ida Cuiaba',            monthlyValue: 158.56, remainingInstallments: 2 },
  { cardId: itauId, description: 'Imp 3d Pai',                   monthlyValue: 400,    remainingInstallments: 3 },
  { cardId: itauId, description: 'Rolamento Supr Ima',           monthlyValue: 50.90,  remainingInstallments: 5 },
  // MP
  { cardId: mpId, description: 'Globauto 5w40 Valv Supr.',      monthlyValue: 42.50,  remainingInstallments: 3 },
  { cardId: mpId, description: 'Passeio 4x4 Penedo',            monthlyValue: 100,    remainingInstallments: 1 },
  // Renner
  { cardId: renId, description: 'Iguatemi',                      monthlyValue: 198.36, remainingInstallments: 5 },
];
installments.forEach(i => {
  db.financeInstallment.insertOne({ ...i, userId, createdAt: new Date() });
});

// ==================== Month Data ====================
print('Inserting month data...');

// April 2026 - payments and invoices
db.financeMonth.insertOne({
  userId,
  yearMonth: '2026-04',
  payments: [
    { expenseId: expIds[15].toString(), expenseName: 'Previdência',   amountPaid: 924.48,  paidAt: new Date('2026-04-07T22:12:21.272Z') },
    { expenseId: expIds[16].toString(), expenseName: 'Pl. Saúde',    amountPaid: 512.81,  paidAt: new Date('2026-04-07T22:12:22.083Z') },
    { expenseId: expIds[21].toString(), expenseName: 'Aluguel',      amountPaid: 4181,    paidAt: new Date('2026-04-07T22:12:22.855Z') },
    { expenseId: expIds[22].toString(), expenseName: 'Paty Omega',   amountPaid: 1000,    paidAt: new Date('2026-04-07T22:12:23.557Z') },
    { expenseId: expIds[0].toString(),  expenseName: 'Linode',       amountPaid: 145,     paidAt: new Date('2026-04-07T22:12:31.295Z') },
    { expenseId: expIds[1].toString(),  expenseName: 'Github',       amountPaid: 220,     paidAt: new Date('2026-04-07T22:12:34.491Z') },
    { expenseId: expIds[6].toString(),  expenseName: 'Internet',     amountPaid: 150,     paidAt: new Date('2026-04-07T22:12:35.634Z') },
  ],
  cardInvoices: [
    { cardId: itauId.toString(), cardName: 'ITAU', invoiceTotal: 13315.12, paid: true },
    { cardId: mpId.toString(),   cardName: 'MP',   invoiceTotal: 151.43,   paid: true },
    { cardId: nbId.toString(),   cardName: 'NB',   invoiceTotal: 0,        paid: true },
  ],
});

// May 2026 - invoices only
db.financeMonth.insertOne({
  userId,
  yearMonth: '2026-05',
  payments: [],
  cardInvoices: [
    { cardId: mpId.toString(),   cardName: 'MP',   invoiceTotal: 216.52,  paid: false },
    { cardId: itauId.toString(), cardName: 'ITAU', invoiceTotal: 9886.28, paid: false },
    { cardId: bbId.toString(),   cardName: 'BB',   invoiceTotal: 1354.80, paid: false },
  ],
});

print('Seed completed!');
print('Cards: ' + db.financeCard.countDocuments({ userId }));
print('Expenses: ' + db.financeExpense.countDocuments({ userId }));
print('Installments: ' + db.financeInstallment.countDocuments({ userId }));
print('Months: ' + db.financeMonth.countDocuments({ userId }));
